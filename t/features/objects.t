use v6;
use Test;
use _007::Test;

{
    my @exprs = «
        '{}'  "(object)"
        '{"a": 1}' '(object (property "a" (int 1)))'
        '{a}' '(object (property "a" (ident "a")))'
        '{a : 1}' '(object (property "a" (int 1)))'
        '{ a: 1}' '(object (property "a" (int 1)))'
        '{a: 1 }' '(object (property "a" (int 1)))'
        '{a: 1}' '(object (property "a" (int 1)))'
        '{a() {}}' '(object (property "a" (block (paramlist) (stmtlist))))'
        '{a(a, b) {}}' '(object (property "a" (block
          (paramlist (ident "a") (ident "b")) (stmtlist))))'
    »;

    for @exprs -> $expr, $frag {
        my $ast = qq[(stmtlist (my (ident "a")) (stexpr {$frag}))];

        parses-to "my a; ($expr)", $ast, $expr;
    }
}

{
    my $ast = q:to/./;
        (stmtlist
          (my (ident "o")
            (object (property "a" (int 1))))
          (stexpr (call (ident "say") (arglist
            (access (ident "o") (ident "a"))))))
        .

    is-result $ast, "1\n", "can access an object's property";
}

{
    my $ast = q:to/./;
          (stmtlist
            (my (ident "o") (object))
            (stexpr (access (ident "o") (ident "a"))))
        .

    is-error $ast, X::PropertyNotFound, "can't access non-existing property";
}

done-testing;