T = 0.0

"""
    LanguageServerInstance(pipe_in, pipe_out, debug=false, env="", depot="")

Construct an instance of the language server.

Once the instance is `run`, it will read JSON-RPC from `pipe_out` and
write JSON-RPC from `pipe_in` according to the [language server
specification](https://microsoft.github.io/language-server-protocol/specifications/specification-3-14/).
For normal usage, the language server can be instantiated with
`LanguageServerInstance(stdin, stdout, false, "/path/to/environment")`.

# Arguments
- `pipe_in::IO`: Pipe to read JSON-RPC from.
- `pipe_out::IO`: Pipe to write JSON-RPC to.
- `debug::Bool`: Whether to log debugging information with `Base.CoreLogging`.
- `env::String`: Path to the
  [environment](https://docs.julialang.org/en/v1.2/manual/code-loading/#Environments-1)
  for which the language server is running. An empty string uses julia's
  default environment.
- `depot::String`: Sets the
  [`JULIA_DEPOT_PATH`](https://docs.julialang.org/en/v1.2/manual/environment-variables/#JULIA_DEPOT_PATH-1)
  where the language server looks for packages required in `env`.
"""
mutable struct LanguageServerInstance
    jr_endpoint::JSONRPCEndpoints.JSONRPCEndpoint
    workspaceFolders::Set{String}
    documents::Dict{URI2,Document}

    debug_mode::Bool
    runlinter::Bool
    ignorelist::Set{String}
    isrunning::Bool
    
    env_path::String
    depot_path::String
    symbol_server::SymbolServer.SymbolServerInstance
    symbol_results_channel::Channel{Any}
    symbol_store::Dict{String,SymbolServer.ModuleStore}
    # ss_task::Union{Nothing,Future}
    format_options::DocumentFormat.FormatOptions
    lint_options::StaticLint.LintOptions

    combined_msg_queue::Channel{Any}

    err_handler::Union{Nothing,Function}

    function LanguageServerInstance(pipe_in, pipe_out, debug_mode::Bool = false, env_path = "", depot_path = "", err_handler=nothing)
        new(
            JSONRPCEndpoints.JSONRPCEndpoint(pipe_in, pipe_out, err_handler),
            Set{String}(),
            Dict{URI2,Document}(),
            debug_mode,
            true, 
            Set{String}(), 
            false, 
            env_path, 
            depot_path, 
            SymbolServer.SymbolServerInstance(depot_path), 
            Channel(Inf),
            deepcopy(SymbolServer.stdlibs),
            DocumentFormat.FormatOptions(), 
            StaticLint.LintOptions(),
            Channel{Any}(Inf),
            err_handler
        )
    end
end
function Base.display(server::LanguageServerInstance)
    println("Root: ", server.workspaceFolders)
    for (uri, d) in server.documents
        display(d)
    end
end

function trigger_symbolstore_reload(server::LanguageServerInstance)
    @async try
        # TODO Add try catch handler that links into crash reporting
        ssi_ret, payload = SymbolServer.getstore(server.symbol_server, server.env_path)

        if ssi_ret==:success
            push!(server.symbol_results_channel, payload)
        elseif ssi_ret==:failure
            error("The symbol server failed with '$(String(take!(payload)))'")
        end
    catch err
        bt = catch_backtrace()
        if server.err_handler!==nothing
            server.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
end

"""
    run(server::LanguageServerInstance)

Run the language `server`.
"""
function Base.run(server::LanguageServerInstance)
    run(server.jr_endpoint)

    trigger_symbolstore_reload(server)

    @async try
        while true
            msg = JSONRPCEndpoints.get_next_message(server.jr_endpoint)
            put!(server.combined_msg_queue, (type=:clientmsg, msg=msg))
        end
    catch err
        bt = catch_backtrace()
        if server.err_handler!==nothing
            server.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end

    @async try
        while true
            msg = take!(server.symbol_results_channel)
            put!(server.combined_msg_queue, (type=:symservmsg, msg=msg))
        end
    catch err
        bt = catch_backtrace()
        if server.err_handler!==nothing
            server.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
        
    while true
        message = take!(server.combined_msg_queue)

        if message.type==:clientmsg
            msg = message.msg                

            request = parse(JSONRPC.Request, msg)

            try
                res = process(request, server)

                if request.id!=nothing
                    JSONRPCEndpoints.send_success_response(server.jr_endpoint, msg, res)
                end
            catch err
                Base.display_error(stderr, err, catch_backtrace())

                if request.id!=nothing
                    # TODO Make sure this is right
                    JSONRPCEndpoints.send_error_response(server.jr_endpoint, msg, res)
                end
            end        
        elseif message.type==:symservmsg
            msg = message.msg

            server.symbol_store = msg

            for (uri, doc) in server.documents
                # only do a pass on documents once
                root = getroot(doc)
                if !(root in roots)
                    push!(roots, root)
                    scopepass(root, doc)
                end

                StaticLint.check_all(getcst(doc), server.lint_options, server)
                empty!(doc.diagnostics)
                mark_errors(doc, doc.diagnostics)
                publish_diagnostics(doc, server)
            end
        end
    end
end




