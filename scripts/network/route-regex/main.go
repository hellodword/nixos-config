// Compile the preimage of a Go regexp under ASCII lowercasing. dnsdist's
// RE2Rule sees the original QNAME, while sing-box matches its lowercase form.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp/syntax"
	"unicode"
)

func lower(c rune) rune {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

func characterClass(matches func(rune) bool) *syntax.Regexp {
	var ranges []rune
	for c := rune(0); c < 128; c++ {
		if !matches(lower(c)) {
			continue
		}
		if len(ranges) > 0 && ranges[len(ranges)-1] == c-1 {
			ranges[len(ranges)-1] = c
		} else {
			ranges = append(ranges, c, c)
		}
	}
	if len(ranges) == 0 {
		never, _ := syntax.Parse(`\b\B`, syntax.Perl)
		return never
	}
	return &syntax.Regexp{Op: syntax.OpCharClass, Rune: ranges}
}

func normalize(expression *syntax.Regexp) *syntax.Regexp {
	switch expression.Op {
	case syntax.OpLiteral:
		parts := make([]*syntax.Regexp, 0, len(expression.Rune))
		for _, expected := range expression.Rune {
			parts = append(parts, characterClass(func(actual rune) bool {
				if actual == expected {
					return true
				}
				if expression.Flags&syntax.FoldCase != 0 {
					for folded := unicode.SimpleFold(expected); folded != expected; folded = unicode.SimpleFold(folded) {
						if actual == folded {
							return true
						}
					}
				}
				return false
			}))
		}
		return &syntax.Regexp{Op: syntax.OpConcat, Sub: parts}
	case syntax.OpCharClass:
		return characterClass(func(actual rune) bool {
			for i := 0; i < len(expression.Rune); i += 2 {
				if actual >= expression.Rune[i] && actual <= expression.Rune[i+1] {
					return true
				}
			}
			return false
		})
	default:
		for i, child := range expression.Sub {
			expression.Sub[i] = normalize(child)
		}
		return expression
	}
}

func main() {
	var patterns []string
	if err := json.NewDecoder(os.Stdin).Decode(&patterns); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result := make(map[string]string, len(patterns))
	for _, pattern := range patterns {
		expression, err := syntax.Parse(pattern, syntax.Perl)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		result[pattern] = ".*(?:" + normalize(expression).String() + ").*"
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
