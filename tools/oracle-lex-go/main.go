package main

import (
	"fmt"
	"go/scanner"
	"go/token"
	"os"
)

func class(tok token.Token, literal string) string {
	switch {
	case tok == token.COMMENT:
		return "comment"
	case tok == token.INT || tok == token.FLOAT || tok == token.IMAG:
		return "number"
	case tok == token.STRING || tok == token.CHAR:
		return "string"
	case tok.IsKeyword():
		return "keyword"
	case tok == token.IDENT:
		return "identifier"
	default:
		return "punctuation"
	}
}

func length(source []byte, offset int, tok token.Token, literal string) int {
	if tok == token.STRING && offset < len(source) && source[offset] == '`' {
		for index := offset + 1; index < len(source); index++ {
			if source[index] == '`' {
				return index - offset + 1
			}
		}

		return len(source) - offset
	}

	if tok == token.COMMENT && offset+1 < len(source) && source[offset+1] == '*' {
		for index := offset + 2; index+1 < len(source); index++ {
			if source[index] == '*' && source[index+1] == '/' {
				return index + 2 - offset
			}
		}

		return len(source) - offset
	}

	if len(literal) > 0 {
		return len(literal)
	}

	return len(tok.String())
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: oracle-lex-go <path>")
		os.Exit(2)
	}

	source, err := os.ReadFile(os.Args[1])

	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	set := token.NewFileSet()
	file := set.AddFile(os.Args[1], set.Base(), len(source))

	var lexer scanner.Scanner
	lexer.Init(file, source, nil, scanner.ScanComments)

	bound := len(source) + 1

	for index := 0; index < bound; index++ {
		position, tok, literal := lexer.Scan()

		if tok == token.EOF {
			break
		}

		if tok == token.SEMICOLON && literal == "\n" {
			offset := file.Offset(position)

			if offset < len(source) {
				fmt.Printf("%d:%d newline\n", offset, 1)
			}

			continue
		}

		if tok == token.LBRACE || tok == token.RBRACE {
			continue
		}

		offset := file.Offset(position)

		fmt.Printf("%d:%d %s\n", offset, length(source, offset, tok, literal), class(tok, literal))
	}
}
