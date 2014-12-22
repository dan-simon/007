role Val {}

role Val::None does Val {
    method Str {
        "None"
    }
}

role Val::Int does Val {
    has Int $.value;

    method Str {
        $.value.Str
    }
}

role Val::Str does Val {
    has Str $.value;

    method Str {
        $.value
    }
}

role Val::Array does Val {
    has @.elements;

    method Str {
        '[' ~ @.elements>>.Str.join(', ') ~ ']'
    }
}

role Val::Block does Val {
    has $.parameters;
    has $.statements;
    has $.outer-frame;

    method Str { "<block>" }
}

role Val::Sub does Val::Block {
    has $.name;

    method Str { "<sub>" }
}

role Val::Sub::Builtin does Val::Sub {
    has $.code;

    method new($code) { self.bless(:$code) }
}

class X::Control::Return is Exception {
    has $.frame;
    has $.value;
}

class X::Subscript::TooLarge is Exception {
}

class X::String::Newline is Exception {
}

class X::PointyBlock::SinkContext is Exception {
}

role Frame {
    has $.block;
    has %.pad;
}

sub children(*@c) {
    "\n" ~ @c.join("\n").indent(2)
}

role Q {
}

role Q::Literal::Int does Q {
    has $.value;
    method new(Int $value) { self.bless(:$value) }
    method Str { "Int[$.value]" }

    method eval($) { Val::Int.new(:$.value) }
}

role Q::Literal::Str does Q {
    has $.value;
    method new(Str $value) { self.bless(:$value) }
    method Str { qq[Str["$.value"]] }

    method eval($) { Val::Str.new(:$.value) }
}

role Q::Literal::Array does Q {
    has @.elements;
    method new(*@elements) {
        self.bless(:@elements)
    }
    method Str { "Array" ~ children(@.elements) }

    method eval($) { Val::Array.new(:elements(@.elements>>.eval($))) }
}

role Q::Literal::Block does Q {
    has $.parameters;
    has $.statements;
    method new($parameters, $statements) { self.bless(:$parameters, :$statements) }
    method Str { "Block" ~ children($.parameters, $.statements) }

    method eval($runtime) {
        my $outer-frame = $runtime.current-frame;
        Val::Block.new(:$.parameters, :$.statements, :$outer-frame);
    }
}

role Q::Term::Identifier does Q {
    has $.name;
    method new(Str $name) { self.bless(:$name) }
    method Str { "Identifier[$.name]" }

    method eval($runtime) {
        return $runtime.get-var($.name);
    }
}

role Q::Expr::Infix does Q {
    has $.lhs;
    has $.rhs;
    has $.type = "";
    method new($lhs, $rhs) { self.bless(:$lhs, :$rhs) }
    method Str { "Infix" ~ self.type ~ children($.lhs, $.rhs) }

    method eval($runtime) { ... }
}

role Q::Expr::Infix::Addition does Q::Expr::Infix {
    method type { "[+]" }
    method eval($runtime) {
        my $lhs = $.lhs.eval($runtime);
        die X::TypeCheck.new(:operation<+>, :got($lhs.^name), :expected<Int>)
            unless $lhs ~~ Val::Int;
        my $rhs = $.rhs.eval($runtime);
        die X::TypeCheck.new(:operation<+>, :got($rhs.^name), :expected<Int>)
            unless $rhs ~~ Val::Int;
        return Val::Int.new(:value(
            $lhs.value + $rhs.value
        ));
    }
}

role Q::Expr::Infix::Concat does Q::Expr::Infix {
    method type { "[~]" }
    method eval($runtime) {
        my $lhs = $.lhs.eval($runtime);
        die X::TypeCheck.new(:operation<~>, :got($lhs.^name), :expected<Str>)
            unless $lhs ~~ Val::Str;
        my $rhs = $.rhs.eval($runtime);
        die X::TypeCheck.new(:operation<~>, :got($lhs.^name), :expected<Str>)
            unless $rhs ~~ Val::Str;
        return Val::Str.new(:value(
            $lhs.value ~ $rhs.value
        ));
    }
}

role Q::Expr::Infix::Assignment does Q::Expr::Infix {
    method type { "[=]" }
    method eval($runtime) {
        die "Needs to be an identifier on the left"     # XXX: Turn this into an X::
            unless $.lhs ~~ Q::Term::Identifier;
        my $value = $.rhs.eval($runtime);
        $runtime.put-var($.lhs.name, $value);
        return $value;
    }
}

role Q::Expr::Infix::Eq does Q::Expr::Infix {
    method type { "[==]" }
    method eval($runtime) {
        multi equal-value(Val $, Val $) { False }
        multi equal-value(Val::None, Val::None) { True }
        multi equal-value(Val::Int $r, Val::Int $l) { $r.value == $l.value }
        multi equal-value(Val::Str $r, Val::Str $l) { $r.value eq $l.value }
        multi equal-value(Val::Array $r, Val::Array $l) {
            return False unless $r.elements == $l.elements;
            for $r.elements.list Z $l.elements.list -> $re, $le {
                return False unless equal-value($re, $le);
            }
            return True;
        }

        my $r = $.rhs.eval($runtime);
        my $l = $.lhs.eval($runtime);
        # converting Bool->Int because the implemented language doesn't have Bool
        my $equal = +equal-value($r, $l);
        return Val::Int.new(:value($equal));
    }
}

role Q::Expr::Index does Q {
    has $.array;
    has $.index;
    method new($array, $index) { self.bless(:$array, :$index) }
    method Str { "Index" ~ children($.array, $.index) }

    method eval($runtime) {
        my $array = $runtime.get-var($.array.name);
        my $index = $.index;
        die X::TypeCheck.new(:operation<indexing>, :got($array.^name), :expected<Array>)
            unless $array ~~ Val::Array;
        # XXX: also check index is integer
        die X::Subscript::TooLarge.new
            if $.index.value >= $array.elements;
        return $array.elements[$index.value];
    }
}

role Q::Expr::Call::Sub does Q {
    has $.expr;
    has $.arguments;
    method new($expr, $arguments) { self.bless(:$expr, :$arguments) }
    method Str { "Call" ~ children($.expr, $.arguments) }

    method eval($runtime) {
        my $c = $.expr.eval($runtime);
        die "Trying to invoke a {$c.^name.subst(/^'Val::'/)}" # XXX: make this into an X::
            unless $c ~~ Val::Block;
        my @args = $.arguments.arguments».eval($runtime);
        return $runtime.call($c, @args);
    }
}

role Q::Statement::VarDecl does Q {
    has $.ident;
    has $.assignment;
    method new($ident, $assignment = Nil) { self.bless(:$ident, :$assignment) }
    method Str { "VarDecl" ~ children($.ident, |$.assignment) }

    method declare($runtime) {
        $runtime.declare-var($.ident.name);
    }

    method run($runtime) {
        return
            unless $.assignment;
        $.assignment.eval($runtime);
    }
}

role Q::Statement::Expr does Q {
    has $.expr;
    method new($expr) { self.bless(:$expr) }
    method Str { "Expr" ~ children($.expr) }

    method declare($runtime) {
        # an expression statement makes no declarations
    }

    method run($runtime) {
        $.expr.eval($runtime);
    }
}

role Q::Statement::If does Q {
    has $.expr;
    has $.block;
    method new($expr, Q::Literal::Block $block) { self.bless(:$expr, :$block) }
    method Str { "If" ~ children($.expr, $.block) }

    method declare($runtime) {
        # an if statement makes no declarations
    }

    method run($runtime) {
        multi truthy(Val::None) { False }
        multi truthy(Val::Int $i) { ?$i.value }
        multi truthy(Val::Str $s) { ?$s.value }
        multi truthy(Val::Array $a) { ?$a.elements }

        if truthy($.expr.eval($runtime)) {
            my $c = $.block.eval($runtime);
            $runtime.enter($c);
            $.block.statements.run($runtime);
            $runtime.leave;
        }
    }
}

role Q::Statement::Block does Q {
    has $.block;
    method new(Q::Literal::Block $block) { self.bless(:$block) }
    method Str { "Statement block" ~ children($.block) }

    method declare($runtime) {
        # an immediate block statement makes no declarations
    }

    method run($runtime) {
        my $c = $.block.eval($runtime);
        $runtime.enter($c);
        $.block.statements.run($runtime);
        $runtime.leave;
    }
}

role Q::Statement::For does Q {
    has $.expr;
    has $.block;
    method new($expr, Q::Literal::Block $block) { self.bless(:$expr, :$block) }
    method Str { "For" ~  children($.expr, $.block)}

    method declare($runtime) {
        # nothing is here so far
    }
    method run($runtime) {
        multi elements(Q::Literal::Array $array) {
            return $array.elements>>.value;
        }

        multi split_elements(@array, 1) { return @array }
        multi split_elements(@array, Int $n) {
            my $list = @array.list;
            my @split;

            while True {
                my @new = $list.splice(0, $n);
                last unless @new;
                @split.push: @new.item;
            }

            @split;
        }

        my $c = $.block.eval($runtime);
        my $count = $c.parameters.parameters.elems;

        if $count == 0 {
            for ^elements($.expr).elems {
                $.block.statements.run($runtime);
            }
        }
        else {
            for split_elements(elements($.expr), $count) -> $arg {
                $runtime.enter($c);
                for $c.parameters.parameters Z $arg.list -> $param, $real_arg {
                    $runtime.declare-var($param.name);
                    $runtime.put-var($param.name, $real_arg);
                }
                $.block.statements.run($runtime);
                $runtime.leave;
            }
        }
    }
}

role Q::Statement::While does Q {
    has $.expr;
    has $.block;
    method new($expr, Q::Literal::Block $block) { self.bless(:$expr, :$block) }
    method Str { "While" ~ children($.expr, $.block) }

    method declare($runtime) {
        # a while loop makes no declarations
    }

    method run($runtime) {
        multi truthy(Val::None) { False }
        multi truthy(Val::Int $i) { ?$i.value }
        multi truthy(Val::Str $s) { ?$s.value }
        multi truthy(Val::Array $a) { ?$a.elements }

        while truthy($.expr.eval($runtime)) {
            my $c = $.block.eval($runtime);
            $runtime.enter($c);
            $.block.statements.run($runtime);
            $runtime.leave;
        }
    }
}

role Q::Statement::Return does Q {
    has $.expr;
    sub NONE { role { method eval($) { Val::None.new }; method Str { "(no return value)" } } }
    method new($expr = NONE) { self.bless(:$expr) }
    method Str { "Return" ~ children($.expr) }

    method declare($runtime) {
        # a return statement makes no declarations
    }

    method run($runtime) {
        my $frame = $runtime.get-var("--RETURN-TO--");
        die X::Control::Return.new(:value($.expr.eval($runtime)), :$frame);
    }
}

role Q::Statement::Sub does Q {
    has $.ident;
    has $.parameters;
    has $.statements;

    method new($ident, $parameters, $statements) {
        self.bless(:$ident, :$parameters, :$statements);
    }
    method Str { "Sub[{$.ident.name}]" ~ children($.parameters, $.statements) }

    method declare($runtime) {
        my $name = $.ident.name;
        my $outer-frame = $runtime.current-frame;
        my $sub = Val::Sub.new(:$name, :$.parameters, :$.statements, :$outer-frame);
        $runtime.declare-var($name);
        $runtime.put-var($name, $sub);
    }

    method run($runtime) {
    }
}

role Q::Statements does Q {
    has @.statements;
    method new(*@statements) { self.bless(:@statements) }
    method Str { "Statements" ~ children(@.statements) }

    method run($runtime) {
        for @.statements -> $statement {
            $statement.run($runtime);
        }
    }
}

role Q::Parameters does Q {
    has @.parameters;
    method new(*@parameters) { self.bless(:@parameters) }
    method Str { "Parameters" ~ children(@.parameters) }
}

role Q::Arguments does Q {
    has @.arguments;
    method new(*@arguments) { self.bless(:@arguments) }
    method Str { "Arguments" ~ children(@.arguments) }
}

constant NO_OUTER = {};

role Runtime {
    has $.output;
    has @!frames;

    method run(Q::Statements $statements) {
        my $parameters = Q::Parameters.new();
        my $setting = Val::Block.new(:$parameters, :statements(Q::Statements.new), :outer-frame(NO_OUTER));
        self.enter($setting);
        self.load-builtins;

        my $block = Val::Block.new(:$parameters, :$statements, :outer-frame(self.current-frame));
        self.enter($block);
        $statements.run(self);
        self.leave for ^2;
        CATCH {
            when X::Control::Return {
                die X::ControlFlow::Return.new;
            }
        }
    }

    method enter($block) {
        my $frame = Frame.new(:$block);
        @!frames.push($frame);
        for $block.statements.statements -> $statement {
            $statement.declare(self);
        }
    }

    method leave {
        @!frames.pop;
    }

    method unroll-to($frame) {
        until self.current-frame === $frame {
            self.leave;
        }
        return;
    }

    method current-frame {
        @!frames[*-1];
    }

    method !find($name) {
        my $frame = self.current-frame;
        loop {
            return $frame.pad
                if $frame.pad{$name} :exists;
            $frame = $frame.block.outer-frame;
            last if $frame === NO_OUTER;
        }
        die "Cannot find variable '$name'";          # XXX: turn this into an X:: type
    }

    method put-var($name, $value) {
        my %pad := self!find($name);
        %pad{$name} = $value;
    }

    method get-var($name) {
        my %pad := self!find($name);
        return %pad{$name};
    }

    method declare-var($name) {
        self.current-frame.pad{$name} = Val::None.new;
    }

    method register-subhandler {
        self.declare-var("--RETURN-TO--");
        self.put-var("--RETURN-TO--", $.current-frame);
    }

    method load-builtins {
        # XXX: should be in a hash
        self.declare-var("say");
        self.put-var("say", Val::Sub::Builtin.new(-> $arg { self.output.say(~$arg) }));
    }

    method sigbind($type, $c, @args) {
        die "$type with {$c.parameters.parameters.elems} parameters "       # XXX: make this into an X::
            ~ "called with {@args.elems} arguments"
            unless $c.parameters.parameters == @args;
        self.enter($c);
        for $c.parameters.parameters Z @args -> $param, $arg {
            my $name = $param.name;
            self.declare-var($name);
            self.put-var($name, $arg);
        }
    }

    multi method call(Val::Block $c, @args) {
        self.sigbind("Block", $c, @args);
        $c.statements.run(self);
        self.leave;
        return Val::None.new;
    }

    multi method call(Val::Sub $c, @args) {
        self.sigbind("Sub", $c, @args);
        self.register-subhandler;
        my $frame = self.current-frame;
        $c.statements.run(self);
        self.leave;
        CATCH {
            when X::Control::Return {
                die $_   # keep unrolling the interpreter's stack until we're there
                    unless .frame === $frame;
                self.unroll-to($frame);
                return .value;
            }
        }
        return Val::None.new;
    }

    multi method call(Val::Sub::Builtin $c, @args) {
        $c.code.(|@args);
        return Val::None.new;
    }
}

class Lexpad {
    has %!variables;

    method add_variable($var) {
        %!variables{$var}++;
    }

    method knows($var) {
        %!variables{$var} :exists;
    }
}

sub add_variable($var) { @*PADS[*-1].add_variable($var) }

class Parser {
    grammar Syntax {
        regex TOP {
            :my @*PADS;
            <.newpad>
            <statements>
        }

        token newpad { <?> { @*PADS.push(Lexpad.new) } }
        token finishpad { <?> { @*PADS.pop } }

        regex statements {
            [<statement> <.eat_terminator> \s*]*
        }

        proto token statement {*}
        token statement:vardecl {
            'my ' <identifier>
            {
                my $var = $<identifier>.Str;
                add_variable($var);
            }
            [' = ' <expr1>]?
        }
        token statement:expr {
            <!before \s* '{'>       # prevent mixup with statement:block
            <expr1>
        }
        token statement:block {
            '{' ~ '}' [
             <.newpad>
             \s* <statements>]
             <.finishpad>
        }
        token statement:sub {
            'sub' \s+
            <identifier>
            {
                my $var = $<identifier>.Str;
                add_variable($var);
            }
            <.newpad>
            '(' ~ ')' <parameters> \s*
            '{' ~ '}' [\s* <statements>]
            <.finishpad>
        }
        token statement:return {
            'return'
            [\s+ <expr1>]?
            \s*
        }
        token statement:if {
            'if' \s+
            <expr1> \s*
            <.newpad>
            '{' ~ '}' [\s* <statements>]
            <.finishpad>
        }
        token statement:for {
            'for' \s+
            <expr1> \s*
            <.newpad>
            ['->' \s* <parameters>]? \s*
            '{' ~ '}' [\s* <statements>]
            <.finishpad>
        }
        token statement:while {
            'while' \s+
            <expr1> \s*
            <.newpad>
            '{' ~ '}' [\s* <statements>]
            <.finishpad>
        }

        token eat_terminator {
            || \s* ';'
            || <?after '}'> $$
            || \s* <?before '}'>
            || \s* $
        }

        # XXX: Besides being hilariously hacky and insufficient, the
        #      whole approach to parsing expressions needs to be
        #      reconsidered when we implement declaring custom operators
        token expr1 { <expr2>+ % [\s* <op> \s*] }
        token expr2 { \s* <expr> <index>* \s* <call>* }

        token index { '[' ~ ']' <expr> }
        token call { '(' ~ ')' <arguments> }

        proto token op {*}
        token op:addition { '+' }
        token op:concat { '~' }
        token op:assignment { '=' }
        token op:eq { '==' }

        proto token expr {*}
        token expr:int { '-'? \d+ }
        token expr:str { '"' (<-["]>*) '"' }
        token expr:array { '[' ~ ']' <expr>* % [\h* ',' \h*] }
        token expr:identifier {
            <identifier>
            {
                my $symbol = $<identifier>.Str;
                die X::Undeclared.new(:$symbol)
                    unless any(@*PADS).knows($symbol)
                     || $symbol eq 'say';   # XXX: remove this exception
            }
        }
        token expr:block { ['->' \s* <parameters>]? \s* '{' ~ '}' [\s* <statements> ] }

        token identifier {
            \w+
        }

        token arguments {
            <expr1>* % [\s* ',' \s*]
        }

        token parameters {
            [<identifier>
                {
                    my $symbol = $<identifier>[*-1].Str;
                    die X::Redeclaration.new(:$symbol)
                        if @*PADS[*-1].knows($symbol);
                    add_variable($symbol);
                }
            ]* % [\s* ',' \s*]
        }
    }

    class Actions {
        method TOP($/) {
            make $<statements>.ast;
        }

        method statements($/) {
            make Q::Statements.new($<statement>».ast);
        }

        method statement:vardecl ($/) {
            if $<expr1> {
                make Q::Statement::VarDecl.new(
                    $<identifier>.ast,
                    Q::Expr::Infix::Assignment.new(
                        $<identifier>.ast,
                        $<expr1>.ast));
            }
            else {
                make Q::Statement::VarDecl.new($<identifier>.ast);
            }
        }

        method statement:expr ($/) {
            die X::PointyBlock::SinkContext.new
                if $<expr1>.ast ~~ Q::Literal::Block;
            make Q::Statement::Expr.new($<expr1>.ast);
        }

        method statement:block ($/) {
            make Q::Statement::Block.new(
                Q::Literal::Block.new(
                    Q::Parameters.new,
                    $<statements>.ast));
        }

        method statement:sub ($/) {
            make Q::Statement::Sub.new(
                $<identifier>.ast,
                $<parameters>.ast,
                $<statements>.ast);
        }

        method statement:return ($/) {
            if $<expr1> {
                make Q::Statement::Return.new(
                    $<expr1>.ast);
            }
            else {
                make Q::Statement::Return.new;
            }
        }

        method statement:if ($/) {
            make Q::Statement::If.new(
                $<expr1>.ast,
                Q::Literal::Block.new(
                    Q::Parameters.new,  # XXX: generalize this (allow '->' syntax)
                    $<statements>.ast));
        }

        method statement:for ($/) {
            my $parameters = ($<parameters> ?? $<parameters>.ast !! Q::Parameters.new);
            make Q::Statement::For.new(
                $<expr1>.ast,
                Q::Literal::Block.new(
                    $parameters,
                    $<statements>.ast));
        }

        method statement:while ($/) {
            make Q::Statement::While.new(
                $<expr1>.ast,
                Q::Literal::Block.new(
                    Q::Parameters.new,  # XXX: generalize this (allow '->' syntax)
                    $<statements>.ast));
        }

        method expr1($/) {
            make $<expr2>[0].ast;
            for ^$<op>.elems -> $i {
                if $<op>[$i].ast === Q::Expr::Infix::Addition
                    && $/.ast ~~ Q::Expr::Infix::Assignment {
                    make Q::Expr::Infix::Assignment.new(
                        $/.ast.lhs,
                        $<op>[$i].ast.new(
                            $/.ast.rhs,
                            $<expr2>[$i+1].ast));
                }
                else {
                    make $<op>[$i].ast.new(
                        $/.ast,
                        $<expr2>[$i+1].ast);
                }
            }
        }

        method expr2($/) {
            make $<expr>.ast;
            for $<index>.list -> $ix {
                make Q::Expr::Index.new(
                    $/.ast,
                    $ix<expr>.ast);
            }
            for $<call>.list -> $call {
                make Q::Expr::Call::Sub.new(
                    $/.ast,
                    $call<arguments>.ast);
            }
        }

        method op:addition ($/) {
            make Q::Expr::Infix::Addition;
        }

        method op:concat ($/) {
            make Q::Expr::Infix::Concat;
        }

        method op:assignment ($/) {
            make Q::Expr::Infix::Assignment;
        }

        method op:eq ($/) {
            make Q::Expr::Infix::Eq;
        }

        method expr:int ($/) {
            make Q::Literal::Int.new(+$/);
        }

        method expr:str ($/) {
            sub check-for-newlines($s) {
                die X::String::Newline.new
                    if $s ~~ /\n/;
            }(~$0);
            make Q::Literal::Str.new(~$0);
        }

        method expr:array ($/) {
            make Q::Literal::Array.new($<expr>».ast);
        }

        method expr:identifier ($/) {
            make $<identifier>.ast;
        }

        method expr:block ($/) {
            my $parameters = ($<parameters> ?? $<parameters>.ast !! Q::Parameters.new);
            make Q::Literal::Block.new(
                $parameters,
                $<statements>.ast);
        }

        method identifier($/) {
            make Q::Term::Identifier.new(~$/);
        }

        method arguments($/) {
            make Q::Arguments.new($<expr1>».ast);
        }

        method parameters($/) {
            make Q::Parameters.new($<identifier>».ast);
        }
    }

    method parse($program) {
        Syntax.parse($program, :actions(Actions))
            or die "Could not parse program";   # XXX: make this into X::
        return $/.ast;
    }
}

role _007 {
    method runtime(:$output = $*OUT) {
        Runtime.new(:$output);
    }

    method parser {
        Parser.new;
    }
}
