"""perl: the language (colours, comments and POD, indentation, F5 with perl or prove), its snippets, the outline
without a language server, Perl Navigator (or Perl::LanguageServer, found in Perl's libraries) and perltidy when they
are installed, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, start
from tplugins import check

SAMPLE = r'''#!/usr/bin/perl
use strict;
use warnings;

# sub notThis { }
use constant PI => 3.14159;

sub main {
    my $s = "sub fake {";
    print "$s\n";   # a comment: sub nope {
    my $n = $#ARGV;
}

package Shape::Square;
use Moo;

has side => (is => 'ro');
has 'label' => (is => 'rw');

sub area {
    my ($self) = @_;
    return $self->side ** 2;
}

sub perimeter($self) { 4 * $self->side }

=pod

sub inPod { }

=cut

package main;
my $text = <<"END";
sub inHeredoc {
END
main();

__END__
sub afterEnd { }'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "perl",
        {"name": "Perl", "extensions": ["pl", "pm", "t", "psgi"], "files": ["cpanfile"], "lineComment": "#",
         "blockComment": ["=pod", "=cut"], "docBlockComment": ["=head1", "=cut"], "quotes": "\"'`",
         "capitalTypes": True, "indentSize": 4, "dedent": "})]",
         "keywords": {"my", "our", "sub", "package", "use", "unless", "elsif", "foreach", "qw", "return", "local"},
         "constants": {"__PACKAGE__", "STDIN", "STDERR"}, "builtins": {"print", "die", "push", "shift", "bless"}},
        ["sub", "package", "if", "foreach", "while", "open", "test"],
        SAMPLE,
        [("PI", "constant", 0), ("main", "function", 0), ("Shape::Square", "module", 0), ("side", "property", 1),
         ("label", "property", 1), ("area", "function", 1), ("perimeter", "function", 1), ("main", "module", 0)],
        ["perl", "prove", "perlnavigator", "perltidy"],
        runs=[("hello.pl", "print 1;\n", {}, "perl -Ilib $file"),
              ("t/basic.t", "use Test::More;\n", {"Makefile.PL": "\n"}, "prove -lv $file"),
              ("bin/app.pl", "print 1;\n", {"cpanfile": "requires 'Moo';\n"}, "perl -Ilib $file")],
        server=["perlnavigator", "--stdio"], formatter="perltidy -st -se")

    # Perl::LanguageServer installed (in a library PERL5LIB names), Perl Navigator not
    tmp = tempfile.mkdtemp(prefix="ned-perl-")
    old = os.environ.get("PERL5LIB")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["perl"])
        lib = os.path.join(tmp, "lib")
        os.makedirs(os.path.join(lib, "Perl"))
        open(os.path.join(lib, "Perl", "LanguageServer.pm"), "w").write("package Perl::LanguageServer;\n1;\n")
        os.environ["PERL5LIB"] = lib
        h, ok, err = start(factory, [fake], only_path=True)
        ls = h.reg("lsp", lang="perl") if ok else None
        check(tag + "Perl::LanguageServer installed (no Perl Navigator): perl -MPerl::LanguageServer -e …::run",
              ok and ls and ls["cmd"] == ["perl", "-MPerl::LanguageServer", "-e", "Perl::LanguageServer::run"],
              (err, ls))
        done(h)
    finally:
        if old is None:
            os.environ.pop("PERL5LIB", None)
        else:
            os.environ["PERL5LIB"] = old
        shutil.rmtree(tmp, ignore_errors=True)
