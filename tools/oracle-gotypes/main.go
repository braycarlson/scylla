package main

import (
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type row struct {
	definition int
	kind       string
	name       string
	offset     int
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

func kindOf(object types.Object) string {
	switch held := object.(type) {
	case *types.Const:
		return "Const"
	case *types.TypeName:
		return "TypeName"
	case *types.Var:
		if held.IsField() {
			return "Field"
		}

		return "Var"
	case *types.Func:
		return "Func"
	case *types.PkgName:
		return "PkgName"
	case *types.Label:
		return "Label"
	case *types.Builtin:
		return "Builtin"
	case *types.Nil:
		return "Nil"
	}

	return "Other"
}

func packages(root string) ([]string, map[string][]string) {
	held := map[string][]string{}

	stack := []string{root}
	seen := map[string]bool{}

	for len(stack) > 0 {
		current := stack[len(stack)-1]
		stack = stack[:len(stack)-1]

		resolved, err := filepath.EvalSymlinks(current)

		if err != nil || seen[resolved] {
			continue
		}

		seen[resolved] = true
		entries, err := os.ReadDir(current)

		if err != nil {
			continue
		}

		for _, entry := range entries {
			path := filepath.Join(current, entry.Name())
			info, err := os.Stat(path)

			if err != nil {
				continue
			}

			if info.IsDir() {
				stack = append(stack, path)

				continue
			}

			if filepath.Ext(path) != ".go" {
				continue
			}

			held[filepath.Dir(path)] = append(held[filepath.Dir(path)], path)
		}
	}

	names := []string{}

	for name := range held {
		sort.Strings(held[name])

		names = append(names, name)
	}

	sort.Strings(names)

	return names, held
}

func skipped(file *ast.File) map[*ast.Ident]bool {
	held := map[*ast.Ident]bool{}

	ast.Inspect(file, func(node ast.Node) bool {
		switch found := node.(type) {
		case *ast.SelectorExpr:
			held[found.Sel] = true
		case *ast.StructType:
			for _, field := range found.Fields.List {
				for _, name := range field.Names {
					held[name] = true
				}
			}
		case *ast.InterfaceType:
			for _, field := range found.Methods.List {
				for _, name := range field.Names {
					held[name] = true
				}
			}
		case *ast.CompositeLit:
			for _, element := range found.Elts {
				pair, ok := element.(*ast.KeyValueExpr)

				if !ok {
					continue
				}

				if key, ok := pair.Key.(*ast.Ident); ok {
					held[key] = true
				}
			}
		}

		return true
	})

	return held
}

func segment(path string, stop int) int {
	start := 1

	for index := 1; index < stop; index++ {
		if path[index] == '/' {
			start = index + 1
		}
	}

	return start
}

func versioned(segment string) bool {
	if len(segment) < 2 || segment[0] != 'v' {
		return false
	}

	for index := 1; index < len(segment); index++ {
		if segment[index] < '0' || segment[index] > '9' {
			return false
		}
	}

	return true
}

func named(file *ast.File, fset *token.FileSet, object types.Object) int {
	for _, spec := range file.Imports {
		if spec.Pos() != object.Pos() {
			continue
		}

		if spec.Name != nil {
			return fset.PositionFor(spec.Name.Pos(), false).Offset
		}

		path := spec.Path.Value
		stop := len(path) - 1
		start := segment(path, stop)

		if start > 1 && versioned(path[start:stop]) {
			stop = start - 1
			start = segment(path, stop)
		}

		return fset.PositionFor(spec.Path.Pos(), false).Offset + start
	}

	return fset.PositionFor(object.Pos(), false).Offset
}

func clauses(paths []string) ([]string, map[string][]string) {
	held := map[string][]string{}
	fset := token.NewFileSet()

	for _, path := range paths {
		source, err := os.ReadFile(path)

		if err != nil {
			continue
		}

		parsed, err := parser.ParseFile(fset, path, source, parser.PackageClauseOnly)

		if parsed == nil || parsed.Name == nil {
			continue
		}

		name := parsed.Name.Name
		held[name] = append(held[name], path)
	}

	names := []string{}

	for name := range held {
		sort.Strings(held[name])

		names = append(names, name)
	}

	sort.Strings(names)

	return names, held
}

func check(
	paths []string,
) (*token.FileSet, map[string]*ast.File, *types.Info, *types.Package, map[string]bool) {
	fset := token.NewFileSet()
	files := []*ast.File{}
	named := map[string]*ast.File{}
	broken := map[string]bool{}

	for _, path := range paths {
		source, err := os.ReadFile(path)

		if err != nil {
			continue
		}

		parsed, err := parser.ParseFile(fset, path, source, parser.ParseComments)

		if parsed == nil {
			continue
		}

		broken[path] = err != nil
		files = append(files, parsed)
		named[path] = parsed
	}

	info := &types.Info{
		Defs:      map[*ast.Ident]types.Object{},
		Implicits: map[ast.Node]types.Object{},
		Uses:      map[*ast.Ident]types.Object{},
	}
	config := &types.Config{
		Error:                    func(error) {},
		Importer:                 importer.Default(),
		DisableUnusedImportCheck: true,
	}

	checked, _ := config.Check("scylla", fset, files, info)

	return fset, named, info, checked, broken
}

func rowsOf(
	fset *token.FileSet,
	path string,
	file *ast.File,
	info *types.Info,
	checked *types.Package,
) []row {
	rows := []row{}
	seen := map[*ast.Ident]bool{}
	away := skipped(file)
	record := func(ident *ast.Ident, object types.Object) {
		if object == nil || seen[ident] || away[ident] || ident.Name == "_" {
			return
		}

		if ident.Name == "." {
			return
		}

		seen[ident] = true
		at := fset.PositionFor(ident.Pos(), false)

		if at.Filename != path {
			return
		}

		kind := kindOf(object)

		if kind == "Field" {
			return
		}

		definition := -1
		foreign := object.Pkg() != nil && object.Pkg() != checked

		if object.Pos() != token.NoPos && !foreign {
			held := fset.PositionFor(object.Pos(), false)

			if held.Filename != "" && held.Filename != path {
				return
			}

			if held.Filename != "" {
				definition = held.Offset
			}
		}

		if kind == "PkgName" {
			definition = named(file, fset, object)
		}

		rows = append(rows, row{
			definition: definition,
			kind:       kind,
			name:       ident.Name,
			offset:     at.Offset,
		})
	}

	for _, spec := range file.Imports {
		object, ok := info.Implicits[spec]

		if !ok || spec.Name != nil {
			continue
		}

		package_name, ok := object.(*types.PkgName)

		if !ok || package_name.Name() == "_" {
			continue
		}

		at := named(file, fset, package_name)

		rows = append(rows, row{
			definition: at,
			kind:       "PkgName",
			name:       package_name.Name(),
			offset:     at,
		})
	}

	ast.Inspect(file, func(node ast.Node) bool {
		held, ok := node.(*ast.TypeSwitchStmt)

		if !ok || held.Assign == nil {
			return true
		}

		assign, ok := held.Assign.(*ast.AssignStmt)

		if !ok || len(assign.Lhs) == 0 {
			return true
		}

		ident, ok := assign.Lhs[0].(*ast.Ident)

		if !ok || ident.Name == "_" {
			return true
		}

		at := fset.PositionFor(ident.Pos(), false)

		if at.Filename != path {
			return true
		}

		seen[ident] = true

		rows = append(rows, row{
			definition: at.Offset,
			kind:       "Var",
			name:       ident.Name,
			offset:     at.Offset,
		})

		return true
	})

	for ident, object := range info.Defs {
		record(ident, object)
	}

	for ident, object := range info.Uses {
		record(ident, object)
	}

	sort.Slice(rows, func(left, right int) bool {
		if rows[left].offset != rows[right].offset {
			return rows[left].offset < rows[right].offset
		}

		return rows[left].name < rows[right].name
	})

	return rows
}

func render(path string, rows []row, broken bool) string {
	var text strings.Builder

	if broken {
		text.WriteString("{\"broken\":true,\"ast\":[")
	} else {
		text.WriteString("{\"ast\":[")
	}

	for index, held := range rows {
		if index > 0 {
			text.WriteString(",")
		}

		fmt.Fprintf(
			&text,
			"[%d,\"%s\",\"%s\",%d]",
			held.offset,
			escape(held.kind),
			escape(held.name),
			held.definition,
		)
	}

	fmt.Fprintf(&text, "],\"path\":\"%s\"}\n", escape(path))

	return text.String()
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle-gotypes <source root> <destination root>")
		os.Exit(2)
	}

	root := os.Args[1]
	destination := os.Args[2]
	names, held := packages(root)
	written := 0

	for _, directory := range names {
		clause, grouped := clauses(held[directory])

		for _, one := range clause {
			fset, files, info, checked, broken := check(grouped[one])

			for path := range files {
				relative, err := filepath.Rel(root, path)

				if err != nil {
					relative = path
				}

				relative = filepath.ToSlash(relative)
				target := filepath.Join(destination, relative+".json")

				if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
					continue
				}

				body := render(relative, rowsOf(fset, path, files[path], info, checked), broken[path])

				if err := os.WriteFile(target, []byte(body), 0o644); err != nil {
					continue
				}

				written++
			}
		}
	}

	fmt.Fprintf(os.Stderr, "wrote %d files\n", written)
}
