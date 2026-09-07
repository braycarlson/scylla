package main

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"

main :: proc() {
    arguments := os.args

    if len(arguments) != 2 {
        fmt.eprintln("usage: oracle-lex-odin <path>")
        os.exit(2)
    }

    source, error := os.read_entire_file_from_path(arguments[1], context.allocator)

    if error != nil {
        fmt.eprintfln("cannot read %s", arguments[1])
        os.exit(2)
    }

    scanner: tokenizer.Tokenizer
    tokenizer.init(&scanner, string(source), arguments[1], silent_error_handler)
    scanner.flags = {.Insert_Semicolon}
    bound := len(source) + 1

    for _ in 0..<bound {
        token := tokenizer.scan(&scanner)

        if token.kind == .EOF {
            break
        }

        if token.kind == .Open_Brace || token.kind == .Close_Brace {
            continue
        }

        if token.kind == .Semicolon && token.text == "\n" {
            if token.pos.offset < len(source) {
                fmt.printfln("%d:%d newline", token.pos.offset, 1)
            }

            continue
        }

        fmt.printfln("%d:%d %s", token.pos.offset, len(token.text), class(token.kind))
    }
}

silent_error_handler :: proc(pos: tokenizer.Pos, message: string, arguments: ..any) {
}

class :: proc(kind: tokenizer.Token_Kind) -> string {
    #partial switch kind {
    case .Ident:
        return "identifier"
    case .Integer, .Float, .Imag:
        return "number"
    case .Rune, .String:
        return "string"
    case .Comment, .File_Tag:
        return "comment"
    }

    if kind > .B_Keyword_Begin && kind < .B_Keyword_End {
        return "keyword"
    }

    return "punctuation"
}
