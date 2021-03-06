use v6;
use _007;
use _007::Val;
use _007::Q;
use _007::Parser::Actions;
use _007::Backend::JavaScript;

use Test;

sub read(Str $ast) is export {
    sub n($type, $op) {
        Q::Identifier.new(:name(Val::Str.new(:value($type ~ ":<$op>"))));
    }

    my %q_lookup =
        none           => Q::Literal::None,
        int            => Q::Literal::Int,
        str            => Q::Literal::Str,
        array          => Q::Term::Array,
        object         => Q::Term::Object,
        regex          => Q::Term::Regex,
        sub            => Q::Term::Sub,
        quasi          => Q::Term::Quasi,

        'prefix:~'     => Q::Prefix::Str,
        'prefix:+'     => Q::Prefix::Plus,
        'prefix:-'     => Q::Prefix::Minus,
        'prefix:^'     => Q::Prefix::Upto,

        'infix:+'      => Q::Infix::Addition,
        'infix:-'      => Q::Infix::Subtraction,
        'infix:*'      => Q::Infix::Multiplication,
        'infix:%'      => Q::Infix::Modulo,
        'infix:%%'     => Q::Infix::Divisibility,
        'infix:~'      => Q::Infix::Concat,
        'infix:::'     => Q::Infix::Cons,
        'infix:='      => Q::Infix::Assignment,
        'infix:=='     => Q::Infix::Eq,
        'infix:!='     => Q::Infix::Ne,
        'infix:~~'     => Q::Infix::TypeMatch,
        'infix:!~'     => Q::Infix::TypeNonMatch,

        'infix:<='     => Q::Infix::Le,
        'infix:>='     => Q::Infix::Ge,
        'infix:<'      => Q::Infix::Lt,
        'infix:>'      => Q::Infix::Gt,

        'postfix:()'   => Q::Postfix::Call,
        'postfix:[]'   => Q::Postfix::Index,
        'postfix:.'    => Q::Postfix::Property,

        my             => Q::Statement::My,
        stexpr         => Q::Statement::Expr,
        if             => Q::Statement::If,
        stblock        => Q::Statement::Block,
        stsub          => Q::Statement::Sub,
        macro          => Q::Statement::Macro,
        return         => Q::Statement::Return,
        for            => Q::Statement::For,
        while          => Q::Statement::While,
        begin          => Q::Statement::BEGIN,

        identifier     => Q::Identifier,
        block          => Q::Block,
        param          => Q::Parameter,
        property       => Q::Property,

        statementlist  => Q::StatementList,
        parameterlist  => Q::ParameterList,
        argumentlist   => Q::ArgumentList,
        propertylist   => Q::PropertyList,
    ;

    my grammar AST::Syntax {
        regex TOP { \s* <expr> \s* }
        proto token expr {*}
        token expr:list { '(' ~ ')' [<expr>+ % \s+] }
        token expr:int { \d+ }
        token expr:str { '"' ~ '"' ([<-["]> | '\\"']*) }
        token expr:symbol { <!before '"'><!before \d> ['()' || <!before ')'> \S]+ }
    }

    my $actions = role {
        method TOP($/) {
            make $<expr>.ast;
        }
        method expr:list ($/) {
            my $qname = ~$<expr>[0];
            die "Unknown name: $qname"
                unless %q_lookup{$qname} :exists;
            my @rest = $<expr>».ast[1..*];
            my $qtype = %q_lookup{$qname};
            my %arguments;
            my @attributes = $qtype.attributes;
            sub check-if-operator() {
                if $qname ~~ /^ [prefix | infix | postfix] ":"/ {
                    # XXX: it stinks that we have to do this
                    %arguments<identifier> = Q::Identifier.new(:name(Val::Str.new(:value($qname))));
                    shift @attributes;  # $.identifier
                }
            }();
            sub aname($attr) { $attr.name.substr(2) }

            if @attributes == 1 && @attributes[0].type ~~ Val::Array {
                my $aname = aname(@attributes[0]);
                %arguments{$aname} = Val::Array.new(:elements(@rest));
            }
            else {
                die "{+@rest} arguments passed, only {+@attributes} parameters expected for {$qtype.^name}"
                    if @rest > @attributes;

                for @attributes.kv -> $i, $attr {
                    if $attr.build && @rest < @attributes {
                        @rest.splice($i, 0, "dummy value to make the indices add up");
                        next;
                    }
                    my $aname = aname($attr);
                    %arguments{$aname} = @rest[$i] // last;
                }
            }
            make $qtype.new(|%arguments);
        }
        method expr:symbol ($/) { make ~$/ }
        method expr:int ($/) { make Val::Int.new(:value(+$/)) }
        method expr:str ($/) { make Val::Str.new(:value((~$0).subst(q[\\"], q["], :g))) }
    };

    AST::Syntax.parse($ast, :$actions)
        or die "couldn't parse AST syntax";
    return Q::CompUnit.new(:block(Q::Block.new(
        :parameterlist(Q::ParameterList.new()),
        :statementlist($/.ast)
    )));
}

my class StrOutput {
    has $.result = "";

    method flush() {}
    method print($s) { $!result ~= $s.gist }
}

my class UnwantedOutput {
    method flush() { die "Program flushed; was not expected to print anything" }
    method print($s) { die "Program printed '$s'; was not expected to print anything" }
}

sub is-result($input, $expected, $desc = "MISSING TEST DESCRIPTION") is export {
    my $ast = read($input);
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$output);
    check($ast.block, $runtime);
    $runtime.run($ast);

    is $output.result, $expected, $desc;
}

sub is-error($input, $expected-error, $expected-msg, $desc = $expected-error.^name) is export {
    my $ast = read($input);
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$output);
    check($ast.block, $runtime);
    $runtime.run($ast);

    CATCH {
        when $expected-error {
            is .message, $expected-msg, $desc;
        }
    }
    flunk $desc;
}

sub empty-diff($text1 is copy, $text2 is copy, $desc) {
    s/<!after \n> $/\n/ for $text1, $text2;  # get rid of "no newline" warnings
    spurt("/tmp/t1", $text1);
    spurt("/tmp/t2", $text2);
    my $diff = qx[diff -U2 /tmp/t1 /tmp/t2];
    $diff.=subst(/^\N+\n\N+\n/, '');  # remove uninformative headers
    is $diff, "", $desc;
}

sub parses-to($program, $expected, $desc = "MISSING TEST DESCRIPTION", Bool :$unexpanded) is export {
    my $expected-ast = read($expected);
    my $output = UnwantedOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    my $actual-ast = $parser.parse($program, :$unexpanded);

    empty-diff ~$expected-ast, ~$actual-ast, $desc;
}

sub parse-error($program, $expected-error, $desc = $expected-error.^name) is export {
    my $output = UnwantedOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    $parser.parse($program);

    CATCH {
        when $expected-error {
            pass $desc;
        }
        default {
            is .^name, $expected-error.^name, $desc;   # which we know will flunk
            return;
        }
    }
    flunk $desc;
}

sub runtime-error($program, $expected-error, $desc = $expected-error.^name) is export {
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    my $ast = $parser.parse($program);
    {
        $runtime.run($ast);

        CATCH {
            when $expected-error {
                pass $desc;
            }
            default {
                is .^name, $expected-error.^name, $desc;   # which we know will flunk
                return;
            }
        }

        is "no error", $expected-error.^name, $desc;
    }
}

sub outputs($program, $expected, $desc = "MISSING TEST DESCRIPTION") is export {
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    my $ast = $parser.parse($program);
    $runtime.run($ast);

    is $output.result, $expected, $desc;
}

sub throws-exception($program, $message, $desc = "MISSING TEST DESCRIPTION") is export {
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    my $ast = $parser.parse($program);
    $runtime.run($ast);

    CATCH {
        when X::_007::RuntimeException {
            is .message, $message, "passing the right Exception's message";
            pass $desc;
        }
    }

    flunk $desc;
}

sub emits-js($program, @expected-builtins, $expected, $desc = "MISSING TEST DESCRIPTION") is export {
    my $output = UnwantedOutput.new;
    my $runtime = _007.runtime(:$output);
    my $parser = _007.parser(:$runtime);
    my $ast = $parser.parse($program);
    my $emitted-js = _007::Backend::JavaScript.new.emit($ast);
    my $actual = $emitted-js ~~ /^^ '(() => { // main program' \n ([<!before '})();'> \N+ [\n|$$]]*)/
        ?? (~$0).indent(*)
        !! $emitted-js;
    my @actual-builtins = $emitted-js.comb(/^^ "function " <(<-[(]>+)>/);

    empty-diff @expected-builtins.sort.join("\n"), @actual-builtins.sort.join("\n"), "$desc (builtins)";
    empty-diff $expected, $actual, $desc;
}

sub run-and-collect-output($filepath, :$input = $*IN) is export {
    my $program = slurp($filepath);
    my $output = StrOutput.new;
    my $runtime = _007.runtime(:$input, :$output);
    my $ast = _007.parser(:$runtime).parse($program);
    $runtime.run($ast);

    return $output.result.lines;
}

sub run-and-collect-error-message($filepath) is export {
    my $program = slurp($filepath);
    my $output = UnwantedOutput.new;
    my $runtime = _007.runtime(:$output);
    my $ast = _007.parser(:$runtime).parse($program);
    $runtime.run($ast);

    CATCH {
        return .message;
    }
}

sub ensure-feature-flag($flag) is export {
    my $envvar = "FLAG_007_{$flag}";
    unless %*ENV{$envvar} {
        skip("$envvar is not enabled", 1);
        done-testing;
        exit 0;
    }
}

sub find($dir, Regex $pattern) is export {
    my @targets = dir($dir);
    my @files;
    while @targets {
        my $file = @targets.shift;
        push @files, $file if $file ~~ $pattern;
        if $file.IO ~~ :d {
            @targets.append: dir($file);
        }
    }
    return @files;
}

our sub EXPORT(*@things) {
    my %exports;
    for @things -> $thing {
        my $routine = EXPORT::ALL::{$thing} // die "Didn't find '$thing'";
        %exports{$thing} = $routine;
    }
    return %exports;
}
