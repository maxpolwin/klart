import Foundation

/// GBNF grammar that constrains sampling to a single valid JSON object
/// (llama.cpp grammar dialect). Used for `CompletionOptions.jsonMode`:
/// stronger than asking nicely in the prompt — the sampler cannot emit a
/// token that would break JSON syntax, so FeedbackParser always gets
/// something parseable from the built-in model.
public enum JSONGrammar {
    public static let object = #"""
    root ::= ws object ws
    value ::= object | array | string | number | "true" | "false" | "null"
    object ::= "{" ws ( member ("," ws member)* )? "}"
    member ::= string ws ":" ws value ws
    array ::= "[" ws ( value ws ("," ws value ws)* )? "]"
    string ::= "\"" char* "\""
    char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
    ws ::= [ \t\n\r]*
    """#
}
