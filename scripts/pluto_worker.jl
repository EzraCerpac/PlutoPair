#!/usr/bin/env julia
using JSON3
using Markdown
using Pkg
using Pluto
using UUIDs
import HTTP

const ROOT = normpath(joinpath(@__DIR__, ".."))
const NOTEBOOKS = Dict{String,Any}()
const SESSIONS = Dict{String,Any}()
const ATTACHED = Dict{String,Any}()

Base.@kwdef mutable struct AttachedNotebook
    handle_id::String
    base_url::String
    secret::Union{Nothing,String}
    notebook_id::String
    path::String
    client_id::String
    request_seq::Int = 0
    outbox::Channel{Any} = Channel{Any}(128)
    pending::Dict{String,Channel{Any}} = Dict{String,Channel{Any}}()
    lock::ReentrantLock = ReentrantLock()
    task::Union{Task,Nothing} = nothing
    closed::Bool = false
    bonds::Dict{String,Any} = Dict{String,Any}()
end

function ok(id, result)
    println(JSON3.write(Dict("id" => id, "ok" => true, "result" => result)))
    flush(stdout)
end

function fail(id, err)
    payload = Dict("id" => id, "ok" => false, "error" => sprint(showerror, err, catch_backtrace()))
    println(JSON3.write(payload))
    flush(stdout)
end

function request_dict(x)
    Dict(String(k) => v for (k, v) in pairs(x))
end

function get_param(params, key, default=nothing)
    haskey(params, key) ? params[key] : default
end

function get_any(dict, key, default=nothing)
    haskey(dict, key) && return dict[key]
    sym = Symbol(key)
    haskey(dict, sym) && return dict[sym]
    return default
end

function base_url_from_params(params)
    url = get_param(params, "url", nothing)
    if !isnothing(url)
        return rstrip(String(url), '/')
    end
    host = String(get_param(params, "host", "127.0.0.1"))
    port = Int(get_param(params, "port", 1234))
    return "http://$(host):$(port)"
end

function with_query(base::AbstractString, endpoint::AbstractString, query::Dict{String,String}=Dict{String,String}())
    uri = HTTP.URI(base * endpoint)
    return string(HTTP.URI(uri; query))
end

function secret_query(secret)
    isnothing(secret) ? Dict{String,String}() : Dict("secret" => String(secret))
end

function infer_secret(base_url::AbstractString)
    for method in ("HEAD", "GET")
        try
            response = HTTP.request(method, base_url * "/"; status_exception=false, retry=false, readtimeout=5)
            cookie = HTTP.header(response, "Set-Cookie", "")
            m = match(r"(?:^|;\s*)secret=([^;]+)", cookie)
            !isnothing(m) && return m.captures[1]
        catch
        end
    end
    return nothing
end

function auth_secret(base_url::AbstractString, supplied)
    isnothing(supplied) || return String(supplied)
    return infer_secret(base_url)
end

function ws_url(att::AttachedNotebook)
    ws_base = startswith(att.base_url, "https://") ? replace(att.base_url, "https://" => "wss://"; count=1) :
              startswith(att.base_url, "http://") ? replace(att.base_url, "http://" => "ws://"; count=1) :
              "ws://" * att.base_url
    return with_query(ws_base, "/channels", secret_query(att.secret))
end

function http_get_bytes(url::AbstractString)
    response = HTTP.get(url; status_exception=false, retry=false, readtimeout=30)
    response.status == 200 || error("HTTP $(response.status) for $url")
    return response.body
end

function unpack_pluto_bytes(bytes)
    return Pluto.unpack(Vector{UInt8}(bytes))
end

function attached_state(att::AttachedNotebook)
    url = with_query(att.base_url, "/statefile", merge(Dict("id" => att.notebook_id), secret_query(att.secret)))
    return unpack_pluto_bytes(http_get_bytes(url))
end

function notebook_is_idle(state)
    results = get_any(state, "cell_results", Dict())
    for (_, result) in pairs(results)
        Bool(get_any(result, "queued", false)) && return false
        Bool(get_any(result, "running", false)) && return false
    end
    return true
end

function wait_attached_idle(att::AttachedNotebook; timeout::Float64=120.0)
    deadline = time() + timeout
    last_state = nothing
    while time() < deadline
        last_state = attached_state(att)
        notebook_is_idle(last_state) && return last_state
        sleep(0.25)
    end
    error("Timed out waiting for attached Pluto notebook to become idle")
end

function ensure_pluto()
    return Pluto
end

function maybe_activate_project(project)
    isnothing(project) && return nothing
    project_path = abspath(String(project))
    if isdir(project_path)
        Pkg.activate(project_path; io=stderr)
    elseif isfile(project_path)
        Pkg.activate(dirname(project_path); io=stderr)
    else
        error("Project path does not exist: $project_path")
    end
    return Base.active_project()
end

function is_pluto_notebook(path::AbstractString)
    isfile(path) || return false
    return occursin("### A Pluto.jl notebook ###", read(path, String))
end

function simple_glob_match(rel::String, patterns)
    isempty(patterns) && return true
    normalized = replace(rel, '\\' => '/')
    for pattern in patterns
        p = replace(String(pattern), '\\' => '/')
        if startswith(p, "**/")
            suffix = p[4:end]
            endswith(normalized, suffix) && return true
        elseif occursin("*", p)
            pieces = split(p, "*")
            pos = firstindex(normalized)
            matched = true
            for piece in pieces
                isempty(piece) && continue
                found = findnext(piece, normalized, pos)
                if isnothing(found)
                    matched = false
                    break
                end
                pos = last(found) + 1
            end
            matched && return true
        elseif normalized == p || endswith(normalized, p)
            return true
        end
    end
    return false
end

function static_bonds(path::AbstractString)
    text = read(path, String)
    names = Set{String}()
    for line in split(text, '\n')
        stripped = strip(line)
        startswith(stripped, "#") && continue
        for m in eachmatch(r"@bind\s+([A-Za-z_][A-Za-z0-9_!]*)", line)
            push!(names, m.captures[1])
        end
    end
    return sort!(collect(names))
end

function send_ws_message(ws, message)
    HTTP.send(ws, Pluto.pack(message))
end

function start_attached!(att::AttachedNotebook)
    ready = Channel{Any}(1)
    att.task = @async begin
        try
            HTTP.WebSockets.open(ws_url(att)) do ws
                put!(ready, true)
                writer = @async begin
                    while true
                        message = take!(att.outbox)
                        message === :close && break
                        send_ws_message(ws, message)
                    end
                    try
                        close(ws)
                    catch
                    end
                end
                try
                    for raw in ws
                        update = unpack_pluto_bytes(raw)
                        initiator = get_any(update, "initiator_id", nothing)
                        request_id = get_any(update, "request_id", nothing)
                        if !isnothing(initiator) && String(initiator) == att.client_id && !isnothing(request_id)
                            lock(att.lock) do
                                channel = get(att.pending, String(request_id), nothing)
                                if !isnothing(channel)
                                    put!(channel, update)
                                end
                            end
                        end
                    end
                finally
                    put!(att.outbox, :close)
                    wait(writer)
                end
            end
        catch err
            if !isready(ready)
                put!(ready, err)
            end
            lock(att.lock) do
                for (_, channel) in att.pending
                    put!(channel, Dict("error" => sprint(showerror, err)))
                end
                empty!(att.pending)
            end
        finally
            att.closed = true
        end
    end
    status = take!(ready)
    status === true || error("Could not attach to Pluto WebSocket: $(status)")
    hello = attached_send(att, "connect", Dict{String,Any}(); metadata=Dict("notebook_id" => att.notebook_id))
    message = get_any(hello, "message", Dict())
    get_any(message, "notebook_exists", false) == true || error("Notebook does not exist in Pluto session: $(att.notebook_id)")
    attached_send(att, "reset_shared_state", Dict{String,Any}(); metadata=Dict("notebook_id" => att.notebook_id))
    return att
end

function attached_send(att::AttachedNotebook, message_type::AbstractString, body=Dict{String,Any}(); metadata=Dict{String,Any}(), timeout::Float64=30.0)
    att.closed && error("Attached Pluto session is closed")
    channel = Channel{Any}(1)
    request_id = lock(att.lock) do
        att.request_seq += 1
        rid = "codex-$(att.request_seq)"
        att.pending[rid] = channel
        rid
    end
    message = Dict{String,Any}(
        "type" => String(message_type),
        "client_id" => att.client_id,
        "request_id" => request_id,
        "body" => body,
    )
    for (key, value) in pairs(metadata)
        message[String(key)] = value
    end
    put!(att.outbox, message)
    deadline = time() + timeout
    while time() < deadline
        if isready(channel)
            response = take!(channel)
            lock(att.lock) do
                delete!(att.pending, request_id)
            end
            haskey(response, "error") && error(response["error"])
            return response
        end
        sleep(0.05)
    end
    lock(att.lock) do
        delete!(att.pending, request_id)
    end
    error("Timed out waiting for Pluto WebSocket response to $(message_type)")
end

function select_option_token(path::AbstractString, bond_name::String, value::AbstractString)
    text = read(path, String)
    pattern = Regex("@bind\\s+$(bond_name)\\s+Select\\s*\\(\\s*\\[(.*?)\\]", "s")
    match = Base.match(pattern, text)
    isnothing(match) && return value
    options_source = match.captures[1]
    option_index = 1
    for option in eachmatch(r":([A-Za-z_][A-Za-z0-9_!]*)\s*=>", options_source)
        if option.captures[1] == value
            return "puiselect-$(option_index)"
        end
        option_index += 1
    end
    return value
end

function compact_code(code::AbstractString)
    stripped = strip(code)
    length(stripped) <= 260 && return stripped
    return first(stripped, 260) * "..."
end

function output_summary(output)
    isnothing(output) && return nothing
    summary = Dict{String,Any}("type" => string(typeof(output)))
    for name in (:mime, :body, :persist_js_state, :rootassignee)
        if hasproperty(output, name)
            value = getproperty(output, name)
            if name == :body
                text = sprint(show, value)
                summary["body"] = length(text) > 1000 ? first(text, 1000) * "..." : text
            else
                summary[String(name)] = string(value)
            end
        end
    end
    isempty(summary) ? Dict("repr" => sprint(show, output)) : summary
end

function log_summary(logs)
    result = Any[]
    for log in collect(logs)
        push!(result, sprint(show, log))
        length(result) >= 20 && break
    end
    return result
end

function cell_summary(cell; include_outputs::Bool)
    payload = Dict{String,Any}(
        "cell_id" => string(cell.cell_id),
        "code" => compact_code(cell.code),
        "queued" => getproperty(cell, :queued),
        "running" => getproperty(cell, :running),
        "errored" => getproperty(cell, :errored),
        "runtime" => getproperty(cell, :runtime),
    )
    if include_outputs
        payload["output"] = output_summary(getproperty(cell, :output))
        payload["logs"] = log_summary(getproperty(cell, :logs))
    end
    return payload
end

function output_summary_js(output)
    isnothing(output) && return nothing
    output isa Dict || return Dict("repr" => sprint(show, output), "type" => string(typeof(output)))
    summary = Dict{String,Any}("type" => string(typeof(output)))
    mime = get_any(output, "mime", nothing)
    body = get_any(output, "body", nothing)
    !isnothing(mime) && (summary["mime"] = string(mime))
    if !isnothing(body)
        text = sprint(show, body)
        summary["body"] = length(text) > 1000 ? first(text, 1000) * "..." : text
    end
    return summary
end

function compact_state_from_js(att::AttachedNotebook, state; include_outputs::Bool=true)
    cell_inputs = get_any(state, "cell_inputs", Dict())
    cell_results = get_any(state, "cell_results", Dict())
    order = collect(get_any(state, "cell_order", Any[]))
    cells = Any[]
    for id in order
        key = string(id)
        input = get(cell_inputs, key, get(cell_inputs, id, Dict()))
        result = get(cell_results, key, get(cell_results, id, Dict()))
        payload = Dict{String,Any}(
            "cell_id" => key,
            "code" => compact_code(String(get_any(input, "code", ""))),
            "queued" => Bool(get_any(result, "queued", false)),
            "running" => Bool(get_any(result, "running", false)),
            "errored" => Bool(get_any(result, "errored", false)),
            "runtime" => get_any(result, "runtime", nothing),
        )
        if include_outputs
            payload["output"] = output_summary_js(get_any(result, "output", nothing))
            payload["logs"] = collect(get_any(result, "logs", Any[]))
        end
        push!(cells, payload)
    end
    bonds = Dict{String,Any}()
    for (name, bondvalue) in pairs(get_any(state, "bonds", Dict()))
        bonds[String(name)] = get_any(bondvalue, "value", nothing)
    end
    for (name, value) in pairs(att.bonds)
        bonds[String(name)] = value
    end
    bond_names = Set{String}(keys(bonds))
    isfile(att.path) && union!(bond_names, static_bonds(att.path))
    return Dict{String,Any}(
        "notebook_id" => att.handle_id,
        "remote_notebook_id" => att.notebook_id,
        "kind" => "attached",
        "url" => att.base_url,
        "path" => String(get_any(state, "path", att.path)),
        "pluto_version" => string(get_any(state, "pluto_version", "")),
        "process_status" => string(get_any(state, "process_status", "")),
        "cell_count" => length(order),
        "cells" => cells,
        "bonds" => bonds,
        "bond_names" => sort!(collect(bond_names)),
    )
end

function compact_state(notebook_id::String; include_outputs::Bool=true)
    if haskey(ATTACHED, notebook_id)
        att = ATTACHED[notebook_id]
        return compact_state_from_js(att, attached_state(att); include_outputs)
    end
    Pluto = ensure_pluto()
    notebook = NOTEBOOKS[notebook_id]
    js = Pluto.notebook_to_js(notebook)
    cells = Any[]
    for cell_id in notebook.cell_order
        push!(cells, cell_summary(notebook.cells_dict[cell_id]; include_outputs))
    end
    bonds = Dict{String,Any}()
    for (name, bondvalue) in notebook.bonds
        value = try
            bondvalue["value"]
        catch
            hasproperty(bondvalue, :value) ? getproperty(bondvalue, :value) : sprint(show, bondvalue)
        end
        bonds[String(name)] = value
    end
    return Dict{String,Any}(
        "notebook_id" => notebook_id,
        "path" => String(notebook.path),
        "pluto_version" => string(get(js, "pluto_version", "")),
        "process_status" => string(get(js, "process_status", "")),
        "cell_count" => length(notebook.cell_order),
        "cells" => cells,
        "bonds" => bonds,
        "bond_names" => sort!(collect(static_bonds(notebook.path))),
    )
end

function decode_notebooklist(base_url::AbstractString, secret)
    url = with_query(base_url, "/notebooklist", secret_query(secret))
    response = HTTP.get(url; status_exception=false, retry=false, readtimeout=10)
    response.status == 200 || return (false, Any[], "HTTP $(response.status)")
    try
        raw = unpack_pluto_bytes(response.body)
        notebooks = Any[]
        for (id, path) in pairs(raw)
            push!(notebooks, Dict(
                "notebook_id" => String(id),
                "path" => String(path),
                "shortpath" => basename(String(path)),
            ))
        end
        sort!(notebooks; by=x -> x["path"])
        return (true, notebooks, nothing)
    catch err
        return (false, Any[], "Authentication required or invalid notebook list response")
    end
end

function pluto_discover_servers(params)
    host = String(get_param(params, "host", "127.0.0.1"))
    ports = collect(get_param(params, "ports", Any[1234]))
    isempty(ports) && (ports = Any[1234])
    servers = Any[]
    for raw_port in ports
        port = Int(raw_port)
        base_url = "http://$(host):$(port)"
        ping_ok = false
        server_header = ""
        try
            response = HTTP.get(base_url * "/ping"; status_exception=false, retry=false, connect_timeout=2, readtimeout=5)
            ping_ok = response.status == 200
            server_header = HTTP.header(response, "Server", "")
        catch
            ping_ok = false
        end
        ping_ok || continue
        secret = infer_secret(base_url)
        ok_list, notebooks, note = decode_notebooklist(base_url, secret)
        push!(servers, Dict(
            "url" => base_url,
            "host" => host,
            "port" => port,
            "server" => server_header,
            "authenticated" => ok_list,
            "secret_inferred" => !isnothing(secret),
            "secret" => secret,
            "notebooks" => notebooks,
            "note" => note,
        ))
    end
    sort!(servers; by=x -> x["port"] == 1234 ? 0 : x["port"])
    return Dict("servers" => servers)
end

function resolve_remote_notebook(base_url::AbstractString, secret, params)
    notebook_id = get_param(params, "notebook_id", nothing)
    path = get_param(params, "path", nothing)
    ok_list, notebooks, note = decode_notebooklist(base_url, secret)
    ok_list || error("Could not list Pluto notebooks at $(base_url): $(note)")
    if !isnothing(notebook_id)
        wanted = String(notebook_id)
        for notebook in notebooks
            notebook["notebook_id"] == wanted && return notebook
        end
        error("Notebook id not found on Pluto server: $(wanted)")
    end
    if !isnothing(path)
        wanted = abspath(String(path))
        matches = [notebook for notebook in notebooks if abspath(notebook["path"]) == wanted]
        length(matches) == 1 && return first(matches)
        isempty(matches) && error("Notebook path not found on Pluto server: $(wanted)")
        error("Notebook path is ambiguous on Pluto server: $(wanted)")
    end
    length(notebooks) == 1 && return first(notebooks)
    error("Specify notebook_id or path; Pluto server has $(length(notebooks)) notebooks open")
end

function attach_to_remote(base_url::AbstractString, secret, notebook)
    remote_id = String(notebook["notebook_id"])
    handle_id = "attached:" * remote_id
    if haskey(ATTACHED, handle_id)
        att = ATTACHED[handle_id]
        att.closed || return att
        delete!(ATTACHED, handle_id)
    end
    att = AttachedNotebook(
        handle_id=handle_id,
        base_url=rstrip(base_url, '/'),
        secret=secret,
        notebook_id=remote_id,
        path=String(notebook["path"]),
        client_id="codex-" * replace(string(uuid1()), "-" => ""),
    )
    start_attached!(att)
    try
        state = attached_state(att)
        for (name, bondvalue) in pairs(get_any(state, "bonds", Dict()))
            att.bonds[String(name)] = get_any(bondvalue, "value", nothing)
        end
    catch
    end
    ATTACHED[handle_id] = att
    return att
end

function pluto_attach_session(params)
    base_url = base_url_from_params(params)
    secret = auth_secret(base_url, get_param(params, "secret", nothing))
    notebook = resolve_remote_notebook(base_url, secret, params)
    att = attach_to_remote(base_url, secret, notebook)
    state = compact_state_from_js(att, attached_state(att); include_outputs=false)
    return Dict(
        "notebook_id" => att.handle_id,
        "remote_notebook_id" => att.notebook_id,
        "kind" => "attached",
        "url" => att.base_url,
        "path" => att.path,
        "secret_inferred" => isnothing(get_param(params, "secret", nothing)) && !isnothing(secret),
        "state" => state,
    )
end

function pluto_open_visible(params)
    base_url = base_url_from_params(params)
    secret = auth_secret(base_url, get_param(params, "secret", nothing))
    path = abspath(String(get_param(params, "path")))
    isfile(path) || error("Notebook path does not exist: $path")
    execution_allowed = Bool(get_param(params, "execution_allowed", true))
    query = merge(
        Dict("path" => path, "execution_allowed" => string(execution_allowed)),
        secret_query(secret),
    )
    response = HTTP.get(with_query(base_url, "/open", query); status_exception=false, retry=false, readtimeout=30, redirect=false)
    if response.status ∉ (200, 302, 303)
        error("Could not open notebook in visible Pluto server: HTTP $(response.status)")
    end
    location = HTTP.header(response, "Location", "")
    notebook_id = begin
        m = match(r"id=([A-Za-z0-9-]+)", location)
        isnothing(m) ? nothing : m.captures[1]
    end
    if isnothing(notebook_id)
        ok_list, notebooks, note = decode_notebooklist(base_url, secret)
        ok_list || error("Notebook opened but could not resolve notebook id: $(note)")
        matches = [notebook for notebook in notebooks if abspath(notebook["path"]) == path]
        length(matches) == 1 || error("Notebook opened but path resolution was ambiguous for $(path)")
        notebook_id = first(matches)["notebook_id"]
    end
    browser_query = merge(Dict("id" => String(notebook_id)), secret_query(secret))
    browser_url = with_query(base_url, "/edit", browser_query)
    notebook = Dict("notebook_id" => String(notebook_id), "path" => path)
    att = attach_to_remote(base_url, secret, notebook)
    return Dict(
        "notebook_id" => att.handle_id,
        "remote_notebook_id" => att.notebook_id,
        "kind" => "attached",
        "url" => att.base_url,
        "browser_url" => browser_url,
        "path" => att.path,
        "execution_allowed" => execution_allowed,
        "state" => compact_state_from_js(att, attached_state(att); include_outputs=false),
    )
end

function pluto_list_notebooks(params)
    root = abspath(String(get_param(params, "root", pwd())))
    isdir(root) || error("Root directory does not exist: $root")
    globs = collect(get_param(params, "globs", Any[]))
    notebooks = Any[]
    for (dir, _, files) in walkdir(root)
        for file in files
            endswith(file, ".jl") || continue
            full = joinpath(dir, file)
            rel = relpath(full, root)
            simple_glob_match(rel, globs) || continue
            is_pluto_notebook(full) || continue
            push!(notebooks, Dict("path" => full, "relative_path" => rel, "bonds" => static_bonds(full)))
        end
    end
    sort!(notebooks; by=x -> x["relative_path"])
    return Dict("root" => root, "notebooks" => notebooks)
end

function pluto_open_notebook(params)
    Pluto = ensure_pluto()
    path = abspath(String(get_param(params, "path")))
    isfile(path) || error("Notebook path does not exist: $path")
    maybe_activate_project(get_param(params, "project", nothing))
    execution_allowed = Bool(get_param(params, "execution_allowed", true))
    session = Pluto.ServerSession()
    notebook = Pluto.SessionActions.open(session, path; execution_allowed, run_async=false)
    notebook_id = string(notebook.notebook_id)
    NOTEBOOKS[notebook_id] = notebook
    SESSIONS[notebook_id] = session
    return Dict(
        "notebook_id" => notebook_id,
        "path" => String(notebook.path),
        "execution_allowed" => execution_allowed,
        "bond_names" => sort!(collect(static_bonds(path))),
        "state" => compact_state(notebook_id; include_outputs=false),
    )
end

function pluto_list_bonds(params)
    Pluto = ensure_pluto()
    notebook_id = String(get_param(params, "notebook_id"))
    if haskey(ATTACHED, notebook_id)
        att = ATTACHED[notebook_id]
        state = attached_state(att)
        runtime_names = sort!(String.(collect(keys(get_any(state, "bonds", Dict())))))
        static_names = isfile(att.path) ? static_bonds(att.path) : String[]
        names = sort!(collect(union(Set(runtime_names), Set(static_names))))
        return Dict(
            "notebook_id" => notebook_id,
            "remote_notebook_id" => att.notebook_id,
            "kind" => "attached",
            "bond_names" => names,
            "runtime_bond_names" => runtime_names,
            "static_bond_names" => static_names,
        )
    end
    notebook = NOTEBOOKS[notebook_id]
    session = SESSIONS[notebook_id]
    runtime_names = try
        sort!(String.(collect(Pluto.get_bond_names(session, notebook))))
    catch err
        String[]
    end
    static_names = static_bonds(notebook.path)
    names = sort!(collect(union(Set(runtime_names), Set(static_names))))
    return Dict(
        "notebook_id" => notebook_id,
        "bond_names" => names,
        "runtime_bond_names" => runtime_names,
        "static_bond_names" => static_names,
    )
end

function pluto_set_bonds(params)
    Pluto = ensure_pluto()
    notebook_id = String(get_param(params, "notebook_id"))
    values = request_dict(get_param(params, "values", Dict()))
    if haskey(ATTACHED, notebook_id)
        att = ATTACHED[notebook_id]
        state = attached_state(att)
        existing_bonds = get_any(state, "bonds", Dict())
        patches = Any[]
        for (name, value) in values
            bond_value = value isa AbstractString && isfile(att.path) ? select_option_token(att.path, name, value) : value
            att.bonds[String(name)] = bond_value
            if haskey(existing_bonds, name)
                push!(patches, Dict("op" => "replace", "path" => Any["bonds", name], "value" => Dict("value" => bond_value)))
            else
                push!(patches, Dict("op" => "add", "path" => Any["bonds", name], "value" => Dict("value" => bond_value)))
            end
        end
        response = attached_send(
            att,
            "update_notebook",
            Dict("updates" => patches);
            metadata=Dict("notebook_id" => att.notebook_id),
            timeout=60.0,
        )
        response_message = get_any(get_any(response, "message", Dict()), "response", Dict())
        if get_any(response_message, "update_went_well", nothing) == "👎"
            error("Pluto update_notebook failed: $(get_any(response_message, "why_not", "unknown error"))")
        end
        wait = Bool(get_param(params, "wait", true))
        new_state = wait ? wait_attached_idle(att) : attached_state(att)
        return Dict(
            "notebook_id" => notebook_id,
            "remote_notebook_id" => att.notebook_id,
            "kind" => "attached",
            "updated" => sort!(collect(keys(values))),
            "state" => compact_state_from_js(att, new_state),
        )
    end
    notebook = NOTEBOOKS[notebook_id]
    session = SESSIONS[notebook_id]
    syms = Symbol[]
    for (name, value) in values
        sym = Symbol(name)
        bond_value = value isa AbstractString ? select_option_token(notebook.path, name, value) : value
        notebook.bonds[sym] = Dict("value" => bond_value)
        push!(syms, sym)
    end
    Pluto.set_bond_values_reactive(;
        session,
        notebook,
        bound_sym_names=syms,
        run_async=false,
        is_first_values=fill(false, length(syms)),
    )
    return Dict("notebook_id" => notebook_id, "updated" => sort!(collect(keys(values))), "state" => compact_state(notebook_id))
end

function pluto_read_state(params)
    notebook_id = String(get_param(params, "notebook_id"))
    include_outputs = Bool(get_param(params, "include_outputs", true))
    return compact_state(notebook_id; include_outputs)
end

function pluto_export_html(params)
    Pluto = ensure_pluto()
    notebook_id = String(get_param(params, "notebook_id"))
    if haskey(ATTACHED, notebook_id)
        att = ATTACHED[notebook_id]
        default_path = replace(String(att.path), r"\.jl$" => ".html")
        output_path = abspath(String(get_param(params, "output_path", default_path)))
        query = merge(Dict("id" => att.notebook_id), secret_query(att.secret))
        response = HTTP.get(with_query(att.base_url, "/notebookexport", query); status_exception=false, retry=false, readtimeout=60)
        response.status == 200 || error("Could not export attached notebook: HTTP $(response.status)")
        write(output_path, response.body)
        return Dict("notebook_id" => notebook_id, "remote_notebook_id" => att.notebook_id, "kind" => "attached", "output_path" => output_path, "bytes" => filesize(output_path))
    end
    notebook = NOTEBOOKS[notebook_id]
    default_path = replace(String(notebook.path), r"\.jl$" => ".html")
    output_path = abspath(String(get_param(params, "output_path", default_path)))
    html = Pluto.generate_html(notebook)
    write(output_path, html)
    return Dict("notebook_id" => notebook_id, "output_path" => output_path, "bytes" => filesize(output_path))
end

function pluto_close_notebook(params)
    Pluto = ensure_pluto()
    notebook_id = String(get_param(params, "notebook_id"))
    if haskey(ATTACHED, notebook_id)
        att = ATTACHED[notebook_id]
        att.closed = true
        try
            put!(att.outbox, :close)
        catch
        end
        if !isnothing(att.task)
            deadline = time() + 5.0
            while !istaskdone(att.task) && time() < deadline
                sleep(0.05)
            end
        end
        delete!(ATTACHED, notebook_id)
        return Dict("notebook_id" => notebook_id, "remote_notebook_id" => att.notebook_id, "kind" => "attached", "closed" => true, "detached_only" => true)
    end
    if haskey(NOTEBOOKS, notebook_id)
        session = SESSIONS[notebook_id]
        notebook = NOTEBOOKS[notebook_id]
        try
            Pluto.SessionActions.shutdown(session, notebook; keep_in_session=false, async=false, verbose=false)
        catch
        end
        delete!(NOTEBOOKS, notebook_id)
        delete!(SESSIONS, notebook_id)
    end
    return Dict("notebook_id" => notebook_id, "closed" => true)
end

const METHODS = Dict(
    "pluto_discover_servers" => pluto_discover_servers,
    "pluto_list_notebooks" => pluto_list_notebooks,
    "pluto_open_notebook" => pluto_open_notebook,
    "pluto_attach_session" => pluto_attach_session,
    "pluto_open_visible" => pluto_open_visible,
    "pluto_list_bonds" => pluto_list_bonds,
    "pluto_set_bonds" => pluto_set_bonds,
    "pluto_read_state" => pluto_read_state,
    "pluto_export_html" => pluto_export_html,
    "pluto_close_notebook" => pluto_close_notebook,
)

function main()
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        request = JSON3.read(line)
        id = request.id
        method = String(request.method)
        params = request_dict(get(request, :params, Dict()))
        try
            haskey(METHODS, method) || error("Unknown method: $method")
            ok(id, METHODS[method](params))
        catch err
            fail(id, err)
        end
    end
end

main()
