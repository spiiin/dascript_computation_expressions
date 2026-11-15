options gen2
require dastest/testing_boost public
require daslib/rtti
require daslib/ast
require daslib/fio
require daslib/strings_boost
require strings

// A test that must not compile says so in its own first lines. `expect CODE`
// names each error the compiler has to report, and dastest checks those. The
// comments under them say what the report must look like:
//
//     // diagnostic: text the report must contain
//     // anchor: text of the source line an error must point at
//     // first                the diagnostic is the first error reported
//
// This test compiles every such file of its folder and checks the comments. A
// file with `expect` and no `// diagnostic:` fails it: an error code alone
// does not say which mistake the test is about.

struct Expectation {
    negative : bool                 // the file has an `expect` line
    messages : array<string>
    anchor : string
    first : bool
    anchor_line : int               // the last source line that contains the anchor
}

def private read_text(path : string) : string {
    var text = ""
    fopen(path, "rb") $(f) {
        if (f != null) {
            f |> fread() $(data) {
                text = clone_string(data)
            }
        }
    }
    return text
}

def private directive(line, name : string) : string {
    let prefix = "// {name}:"
    return starts_with(line, prefix) ? strip(slice(line, length(prefix))) : ""
}

def private expectation_of(text : string) : Expectation {
    var result : Expectation
    var number = 0
    for (raw in split(text, "\n")) {
        number++
        let line = strip(raw)
        if (starts_with(line, "expect ")) {
            result.negative = true
        } elif (!empty(directive(line, "diagnostic"))) {
            result.messages |> push(directive(line, "diagnostic"))
        } elif (!empty(directive(line, "anchor"))) {
            result.anchor = directive(line, "anchor")
        } elif (line == "// first") {
            result.first = true
        } elif (!empty(result.anchor) && find(raw, result.anchor) >= 0) {
            result.anchor_line = number
        }
    }
    return <- result
}

struct Report {
    failed : bool
    text : string
    lines : array<int>              // the lines of this file that errors point at
}

def private compile(path : string) : Report {
    var result : Report
    var inscope access <- make_file_access("")
    using() $(var mg : ModuleGroup) {
        using() $(var cop : CodeOfPolicies) {
            cop.threadlock_context = true
            compile_file(path, access, unsafe(addr(mg)), cop) $(ok, program, output) {
                result.failed = !ok
                result.text = "{output}"
                if (program != null) {
                    for (err in program.errors) {
                        if (err.at.fileInfo != null && ends_with(replace(string(err.at.fileInfo.name), "\\", "/"), path)) {
                            result.lines |> push(int(err.at.line))
                        }
                    }
                }
            }
        }
    }
    return <- result
}

def private first_error(text : string) : string {
    for (line in split(text, "\n")) {
        if (starts_with(line, "error[")) {
            return line
        }
    }
    return ""
}

[test]
def test_diagnostics(t : T?) {
    let here = replace(string(get_line_info().fileInfo.name), "\\", "/")
    let slash = rfind(here, "/")
    let folder = slash >= 0 ? slice(here, 0, slash) : "."
    var names : array<string>
    dir(folder) $(name) {
        if (ends_with(name, ".das")) {
            names |> push(clone_string(name))
        }
    }
    sort(names)
    var checked = 0
    for (name in names) {
        let path = "{folder}/{name}"
        var inscope expected <- expectation_of(read_text(path))
        if (!expected.negative) {
            continue
        }
        checked++
        if (!(t |> success(!empty(expected.messages), "{name}: add `// diagnostic: text` under its expect lines"))) {
            continue
        }
        var inscope report <- compile(path)
        if (!(t |> success(report.failed, "{name}: compiled, but must not"))) {
            continue
        }
        for (message in expected.messages) {
            t |> success(find(report.text, message) >= 0, "{name}: the report does not contain '{message}'\n{report.text}")
        }
        t |> success(find(report.text, "macro caused exception") < 0 && find(report.text, "macro integration error") < 0,
            "{name}: the macro itself failed\n{report.text}")
        if (!empty(expected.anchor)) {
            t |> success(expected.anchor_line > 0, "{name}: no source line contains the anchor '{expected.anchor}'")
            t |> success(find_index(report.lines, expected.anchor_line) >= 0,
                "{name}: no error points at line {expected.anchor_line} ('{expected.anchor}')\n{report.text}")
        }
        if (expected.first) {
            t |> success(find(first_error(report.text), expected.messages[0]) >= 0,
                "{name}: '{expected.messages[0]}' is not the first error\n{report.text}")
        }
    }
    // Nothing found means the folder was not read, not that every diagnostic is right.
    t |> success(checked > 0, "no test with `expect` found in {folder}")
}
