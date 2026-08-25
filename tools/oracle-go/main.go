package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

type row struct {
	name  string
	start int
	end   int
}

func escape(text string) string {
	var out strings.Builder

	for _, held := range text {
		switch held {
		case '"':
			out.WriteString("\\\"")
		case '\\':
			out.WriteString("\\\\")
		case '\n':
			out.WriteString("\\n")
		case '\r':
			out.WriteString("\\r")
		case '\t':
			out.WriteString("\\t")
		default:
			out.WriteRune(held)
		}
	}

	return out.String()
}

func walk(fset *token.FileSet, file *ast.File, length int) []row {
	rows := []row{}

	ast.Inspect(file, func(node ast.Node) bool {
		if node == nil {
			return false
		}

		name := reflect.TypeOf(node).Elem().Name()

		if node.Pos() == token.NoPos || node.End() == token.NoPos {
			return true
		}

		start := fset.Position(node.Pos()).Offset
		end := fset.Position(node.End()).Offset

		if start < 0 || end > length || end < start {
			return true
		}

		rows = append(rows, row{name: name, start: start, end: end})

		return true
	})

	return rows
}

func sources(root string) []string {
	found := []string{}

	filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}

		if entry.IsDir() {
			return nil
		}

		if filepath.Ext(path) != ".go" {
			return nil
		}

		found = append(found, path)

		return nil
	})

	sort.Strings(found)

	return found
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle-go <source root> <destination root>")
		os.Exit(2)
	}

	root := os.Args[1]
	destination := os.Args[2]
	skipped := 0

	for _, path := range sources(root) {
		source, err := os.ReadFile(path)

		if err != nil {
			skipped++

			continue
		}

		fset := token.NewFileSet()
		parsed, err := parser.ParseFile(fset, path, source, parser.SkipObjectResolution)

		if err != nil {
			fmt.Fprintf(os.Stderr, "skipped %s (%v)\n", path, err)

			skipped++

			continue
		}

		relative, err := filepath.Rel(root, path)

		if err != nil {
			relative = path
		}

		relative = filepath.ToSlash(relative)
		rows := walk(fset, parsed, len(source))
		var body strings.Builder

		body.WriteString("{\"ast\":[")
		body.WriteString(fmt.Sprintf("[\"File\",0,%d]", len(source)))

		for _, held := range rows {
			if held.name == "File" {
				continue
			}

			body.WriteString(fmt.Sprintf(",[\"%s\",%d,%d]", escape(held.name), held.start, held.end))
		}

		body.WriteString(fmt.Sprintf("],\"broken\":false,\"path\":\"%s\"}\n", escape(relative)))

		target := filepath.Join(destination, relative+".json")

		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return
		}

		if err := os.WriteFile(target, []byte(body.String()), 0o644); err != nil {
			return
		}
	}

	if skipped > 0 {
		fmt.Fprintf(os.Stderr, "skipped %d files\n", skipped)
	}
}
