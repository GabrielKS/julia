# This file is a part of Julia. License is MIT: https://julialang.org/license

# editing and paging files

using Base: shell_split, shell_escape, find_source_file

"""
    EDITOR_CALLBACKS :: Vector{Function}

A vector of editor callback functions, which take as arguments `cmd`, `path`, `line`
and `column` and which is then expected to either open an editor and return `true` to
indicate that it has handled the request, or return `false` to decline the
editing request.
"""
const EDITOR_CALLBACKS = Function[]

"""
    define_editor(fn, pattern; wait=false)

Define a new editor matching `pattern` that can be used to open a file (possibly
at a given line number) using `fn`.

The `fn` argument is a function that determines how to open a file with the
given editor. It should take four arguments, as follows:

* `cmd` - a base command object for the editor
* `path` - the path to the source file to open
* `line` - the line number to open the editor at
* `column` - the column number to open the editor at

Editors which cannot open to a specific line with a command or a specific column
may ignore the `line` and/or `column` argument. The `fn` callback must return
either an appropriate `Cmd` object to open a file or `nothing` to indicate that
they cannot edit this file. Use `nothing` to indicate that this editor is not
appropriate for the current environment and another editor should be attempted.
It is possible to add more general editing hooks that need not spawn
external commands by pushing a callback directly to the vector `EDITOR_CALLBACKS`.

The `pattern` argument is a string, regular expression, or an array of strings
and regular expressions. For the `fn` to be called, one of the patterns must
match the value of `EDITOR`, `VISUAL` or `JULIA_EDITOR`. For strings, the string
must equal the [`basename`](@ref) of the first word of the editor command, with
its extension, if any, removed. E.g. "vi" doesn't match "vim -g" but matches
"/usr/bin/vi -m"; it also matches `vi.exe`. If `pattern` is a regex it is
matched against all of the editor command as a shell-escaped string. An array
pattern matches if any of its items match. If multiple editors match, the one
added most recently is used.

By default julia does not wait for the editor to close, running it in the
background. However, if the editor is terminal based, you will probably want to
set `wait=true` and julia will wait for the editor to close before resuming.

If one of the editor environment variables is set, but no editor entry matches it,
the default editor entry is invoked:

    (cmd, path, line, column) -> `\$cmd \$path`

Note that many editors are already defined. All of the following commands should
already work:

- emacs
- emacsclient
- vim
- nvim
- nano
- micro
- kak
- helix
- textmate
- mate
- kate
- subl
- atom
- notepad++
- Visual Studio Code
- open
- pycharm
- bbedit

# Examples

The following defines the usage of terminal-based `emacs`:

    define_editor(
        r"\\bemacs\\b.*\\s(-nw|--no-window-system)\\b", wait=true) do cmd, path, line
        `\$cmd +\$line \$path`
    end

!!! compat "Julia 1.4"
    `define_editor` was introduced in Julia 1.4.
"""
function define_editor(fn::Function, pattern; wait::Bool=false)
    callback = function (cmd::Cmd, path::AbstractString, line::Integer, column::Integer)
        editor_matches(pattern, cmd) || return false
        editor = if !applicable(fn, cmd, path, line, column)
            # Be backwards compatible with editors that did not define the newly added column argument
            fn(cmd, path, line)
        else
            fn(cmd, path, line, column)
        end
        if editor isa Cmd
            if wait
                run(editor) # blocks while editor runs
            else
                run(pipeline(editor, stderr=stderr), wait=false)
            end
            return true
        elseif editor isa Nothing
            return false
        end
        @warn "invalid editor value returned" pattern=pattern editor=editor
        return false
    end
    pushfirst!(EDITOR_CALLBACKS, callback)
end

editor_matches(p::Regex, cmd::Cmd) = occursin(p, shell_escape(cmd))
editor_matches(p::String, cmd::Cmd) = p == splitext(basename(first(cmd)))[1]
editor_matches(ps::AbstractArray, cmd::Cmd) = any(editor_matches(p, cmd) for p in ps)

function define_default_editors()
    # fallback: just call the editor with the path as argument
    define_editor(r".*") do cmd, path, line, column
        `$cmd $path`
    end
    # vim family
    for (editors, wait) in [
        [["vim", "vi", "nvim", "mvim"], true],
        [[r"\bgvim"], false],
    ]
        define_editor(editors; wait) do cmd, path, line, column
            cmd = line == 0 ? `$cmd $path` :
                column == 0 ? `$cmd +$line $path` :
                `$cmd "+normal $(line)G$(column)|" $path`
        end
    end
    define_editor("nano"; wait=true) do cmd, path, line, column
        cmd = `$cmd +$line,$column $path`
    end
    # emacs (must check that emacs not running in -t/-nw
    # before regex match for general emacs)
    for (editors, wait) in [
        [[r"\bemacs"], false],
        [[r"\bemacs\b.*\s(-nw|--no-window-system)\b",
          r"\bemacsclient\b.\s*-(-?nw|t|-?tty)\b"], true],
    ]
        define_editor(editors; wait) do cmd, path, line, column
            `$cmd +$line:$column $path`
        end
    end
    # other editors
    define_editor("gedit") do cmd, path, line, column
        `$cmd +$line:$column $path`
    end
    define_editor(["micro", "kak"]; wait=true) do cmd, path, line, column
        `$cmd +$line $path`
    end
    define_editor(["hx", "helix"]; wait=true) do cmd, path, line, column
        `$cmd $path:$line:$column`
    end
    define_editor(["textmate", "mate", "kate"]) do cmd, path, line, column
        `$cmd $path -l $line`
    end
    define_editor([r"\bsubl", r"\batom", "pycharm", "bbedit"]) do cmd, path, line, column
        `$cmd $path:$line`
    end
    define_editor(["code", "code-insiders"]) do cmd, path, line, column
        `$cmd -g $path:$line:$column`
    end
    define_editor(r"\bnotepad++") do cmd, path, line, column
        `$cmd $path -n$line`
    end
    if Sys.iswindows()
        define_editor(r"\bCODE\.EXE\b"i) do cmd, path, line, column
            `$cmd -g $path:$line:$column`
        end
        callback = function (cmd::Cmd, path::AbstractString, line::Integer)
            cmd == `open` || return false
            # don't emit this ccall on other platforms
            @static if Sys.iswindows()
                result = ccall((:ShellExecuteW, "shell32"), stdcall,
                               Int, (Ptr{Cvoid}, Cwstring, Cwstring,
                                     Ptr{Cvoid}, Ptr{Cvoid}, Cint),
                               C_NULL, "open", path, C_NULL, C_NULL, 10)
                systemerror(:edit, result ≤ 32)
            end
            return true
        end
        pushfirst!(EDITOR_CALLBACKS, callback)
    elseif Sys.isapple()
        define_editor("open") do cmd, path, line, column
            `open -t $path`
        end
    end
end
define_default_editors()

"""
    editor()

Determine the editor to use when running functions like `edit`. Returns a `Cmd`
object. Change editor by setting `JULIA_EDITOR`, `VISUAL` or `EDITOR`
environment variables.
"""
function editor()
    # Note: the editor path can include spaces (if escaped) and flags.
    for var in ["JULIA_EDITOR", "VISUAL", "EDITOR"]
        str = get(ENV, var, nothing)
        str === nothing && continue
        isempty(str) && error("invalid editor \$$var: $(repr(str))")
        return Cmd(shell_split(str))
    end
    editor_file = "/etc/alternatives/editor"
    editor = (Sys.iswindows() || Sys.isapple()) ? "open" :
        isfile(editor_file) ? realpath(editor_file) : "emacs"
    return Cmd([editor])
end

"""
    edit(path::AbstractString, line::Integer=0, column::Integer=0)

Edit a file or directory optionally providing a line number to edit the file at.
Return to the `julia` prompt when you quit the editor. The editor can be changed
by setting `JULIA_EDITOR`, `VISUAL` or `EDITOR` as an environment variable.

!!! compat "Julia 1.9"
    The `column` argument requires at least Julia 1.9.

See also [`InteractiveUtils.define_editor`](@ref).
"""
function edit(path::AbstractString, line::Integer=0, column::Integer=0)
    path isa String || (path = convert(String, path))
    if endswith(path, ".jl")
        p = find_source_file(path)
        p !== nothing && (path = p)
    end
    cmd = editor()
    for callback in EDITOR_CALLBACKS
        if !applicable(callback, cmd, path, line, column)
            callback(cmd, path, line) && return
        else
            callback(cmd, path, line, column) && return
        end
    end
    # shouldn't happen unless someone has removed fallback entry
    error("no editor found")
end

"""
    edit(function, [types])
    edit(module)

Edit the definition of a function, optionally specifying a tuple of types to indicate which
method to edit. For modules, open the main source file. The module needs to be loaded with
`using` or `import` first.

!!! compat "Julia 1.1"
    `edit` on modules requires at least Julia 1.1.

To ensure that the file can be opened at the given line, you may need to call
`InteractiveUtils.define_editor` first.
"""
function edit(@nospecialize f)
    ms = methods(f).ms
    length(ms) == 1 && edit(functionloc(ms[1])...)
    length(ms) > 1 && return ms
    length(ms) == 0 && functionloc(f) # throws
    nothing
end
edit(m::Method) = edit(functionloc(m)...)
edit(@nospecialize(f), idx::Integer) = edit(methods(f).ms[idx])
edit(f, t) = (@nospecialize; edit(functionloc(f, t)...))
edit(@nospecialize argtypes::Union{Tuple, Type{<:Tuple}}) = edit(functionloc(argtypes)...)
edit(file::Nothing, line::Integer) = error("could not find source file for function")
edit(m::Module) = edit(pathof(m))

# terminal pager

if Sys.iswindows()
    function less(file::AbstractString, line::Integer)
        pager = shell_split(get(ENV, "PAGER", "more"))
        if pager[1] == "more"
            g = ""
            line -= 1
        else
            g = "g"
        end
        run(Cmd(`$pager +$(line)$(g) \"$file\"`, windows_verbatim = true))
        nothing
    end
else
    function less(file::AbstractString, line::Integer)
        pager = shell_split(get(ENV, "PAGER", "less"))
        run(`$pager +$(line)g $file`)
        nothing
    end
end

"""
    less(file::AbstractString, [line::Integer])

Show a file using the default pager, optionally providing a starting line number. Returns to
the `julia` prompt when you quit the pager.
"""
less(file::AbstractString) = less(file, 1)

"""
    less(function, [types])

Show the definition of a function using the default pager, optionally specifying a tuple of
types to indicate which method to see.
"""
less(f)                   = less(functionloc(f)...)
less(f, @nospecialize t)  = less(functionloc(f,t)...)
less(file, line::Integer) = error("could not find source file for function")
