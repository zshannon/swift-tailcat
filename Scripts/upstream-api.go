// Emit root exported function/method declarations, including all build variants.
// Parsing source avoids dependency loading and never executes upstream code.
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

type entry struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	Signature string `json:"signature"`
}

// Exported methods on private receiver types are not root public declarations.
func exportedReceiver(expression ast.Expr) bool {
	switch receiver := expression.(type) {
	case *ast.Ident:
		return receiver.IsExported()
	case *ast.IndexExpr:
		return exportedReceiver(receiver.X)
	case *ast.IndexListExpr:
		return exportedReceiver(receiver.X)
	case *ast.StarExpr:
		return exportedReceiver(receiver.X)
	}
	return false
}

func inventory(root string) ([]entry, error) {
	files, err := os.ReadDir(root) // Sorted by filename; declarations retain source order.
	if err != nil {
		return nil, err
	}
	entries := []entry{}
	for _, file := range files {
		name := file.Name()
		if file.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		source, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			return nil, err
		}
		positions := token.NewFileSet()
		parsed, err := parser.ParseFile(positions, name, source, 0)
		if err != nil {
			return nil, err
		}
		for _, declaration := range parsed.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || !function.Name.IsExported() ||
				(function.Recv != nil && !exportedReceiver(function.Recv.List[0].Type)) {
				continue
			}
			start, end := positions.Position(function.Pos()), positions.Position(function.End())
			if function.Body != nil {
				end = positions.Position(function.Body.Pos())
			}
			entries = append(entries, entry{
				File:      name,
				Line:      start.Line,
				Signature: strings.TrimSpace(string(source[start.Offset:end.Offset])),
			})
		}
	}
	return entries, nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: upstream-api module-directory")
		os.Exit(1)
	}
	entries, err := inventory(os.Args[1])
	if err == nil {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetEscapeHTML(false)
		encoder.SetIndent("", "  ")
		err = encoder.Encode(entries)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
