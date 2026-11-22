#!/usr/bin/perl
# fix-refs.pl scan|fix ROOT < NUL-separated file list (git ls-files -z)
#
# Rewrites references to repos that moved from $FROM to $TO inside tracked
# files: github.com URLs, `uses:` lines, ghcr.io image paths, <owner>.github.io
# Pages URLs, badges, API paths, "owner/repo" strings.
#
#   scan  prints "file:line:text" for every line that would change, and
#         "REVIEW file:line:text" for lines that mention $FROM but are left alone
#   fix   rewrites the files and prints the names of changed files
#
# Environment:
#   FROM, TO   owner logins
#   NAMES      file with one moved repo name per line (the current names)
#   IMAGES     optional file with one container image name per line that exists
#              under ghcr.io/$TO; other ghcr.io/$FROM/<image> paths are left alone
#
# Deliberately left alone (reported as REVIEW):
#   - lines that already name both owners (dual-owner matchers such as OIDC
#     trust lists are kept so either location keeps working)
#   - $FROM/<name> where <name> is not a moved repo
#   - lockfiles and Go sources (module paths resolve through redirects)
#
# Only safe when $FROM is not a prefix of other identifiers. When FROM is a
# plain user login that is also an npm scope (@crvouga/...), the owner is only
# rewritten in the URL/workflow contexts listed in $ctx below.
use strict; use warnings;
my ($mode, $root) = @ARGV;
die "usage: fix-refs.pl scan|fix ROOT\n" unless $mode && $root;
my ($FROM, $TO) = ($ENV{FROM}, $ENV{TO});
my (%name, %img);
sub load { my ($f, $h) = @_; return unless $f; open my $fh, '<', $f or return;
  while (<$fh>) { chomp; $h->{lc $_} = $_ if length } close $fh }
load($ENV{NAMES}, \%name); load($ENV{IMAGES}, \%img);
my $have_img = scalar %img;

# Longest prefix of a token that is a moved repo name, plus the leftover suffix.
sub split_name { my $tok = shift; my $t = $tok;
  while (length $t) {
    return ($t, substr($tok, length $t)) if exists $name{lc $t};
    next if $t =~ s/\.git$//;
    last unless $t =~ s/[._-]$//;
  }
  return }

# When $FROM contains $TO (crvouga-organization -> crvouga) every occurrence is
# unambiguous. The other way round the owner must be anchored to a context.
my $anchored = index($FROM, $TO) < 0;
my $ctx = qr{(?:api\.github\.com/repos/|githubusercontent\.com/|github\.com[/:]|uses:\s*["']?|repository:\s*["']?|"repository"\s*:\s*"|github:|gh\s+repo\s+(?:clone|view|fork)\s+|(?:-R|--repo)[ =]["']?|(?:degit|tiged)\s+|codecov\.io/(?:gh|github)/|badgen\.net/github/[a-z-]+/|img\.shields\.io/[^\s)"'\]>]*?/|star-history\.com/\#|GITHUB_REPOSITORY[=:]\s*["']?|repo:)}i;

sub rewrite_line { my $l = shift;
  # ghcr.io/$FROM/<image>
  $l =~ s{\bghcr\.io/\Q$FROM\E/([a-z0-9][a-z0-9._-]*)}{
    my $i = $1; (my $b = $i) =~ s/[._-]+$//;
    (!$have_img || $img{lc $b}) ? "ghcr.io/$TO/$i" : "ghcr.io/$FROM/$i" }gie;
  # $FROM.github.io/<repo>
  $l =~ s{\b\Q$FROM\E\.github\.io/([A-Za-z0-9_.-]+)}{
    my $tok = $1; my ($n, $rest) = split_name($tok);
    defined $n ? lc($TO) . ".github.io/$name{lc $n}$rest" : "$FROM.github.io/$tok" }gie;
  # $FROM/<repo>
  my $pre = $anchored ? qr{($ctx)} : qr{()};
  $l =~ s{$pre(?<![A-Za-z0-9_-])\Q$FROM\E/([A-Za-z0-9_.-]+)}{
    my ($p, $tok) = ($1, $2); my ($n, $rest) = split_name($tok);
    defined $n ? "$p$TO/$name{lc $n}$rest" : "$p$FROM/$tok" }gie;
  return $l }

local $/ = "\0";
while (my $f = <STDIN>) {
  chomp $f;
  my $p = "$root/$f";
  next if -l $p || ! -f $p || -s $p > 5_000_000;
  (my $base = $f) =~ s{.*/}{};
  next if $base =~ /\.go$/ || $base =~ /^(?:go\.(?:mod|sum|work|work\.sum)|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Cargo\.lock|poetry\.lock|uv\.lock|Gemfile\.lock|composer\.lock|deno\.lock|flake\.lock)$/;
  next unless -T $p;
  open my $fh, '<:raw', $p or next; my $s = do { local $/; <$fh> }; close $fh;
  next unless $s =~ /\Q$FROM\E/i;
  my ($out, $n, $changed) = ('', 0, 0);
  for my $l (split /(?<=\n)/, $s) {
    $n++;
    if ($l !~ /\Q$FROM\E/i) { $out .= $l; next }
    (my $rest = $l) =~ s/\Q$FROM\E//gi;
    # "Both owners" means $TO also appears as a bare owner or an owner wildcard
    # ("crvouga", crvouga/*), not as an npm scope (@crvouga/pkg), a longer word
    # (crvouga-skills) or an owner/repo path (crvouga/workspace).
    my $both = !$anchored && $rest =~ m~(?<![\@A-Za-z0-9_./-])\Q$TO\E(?=/\*|["'`\s,|)\]};:]|$)~i;
    my $new = $both ? $l : rewrite_line($l);
    (my $show = $l) =~ s/\s+$//; $show = substr($show, 0, 300);
    if ($new ne $l) { $changed = 1; print "$f:$n:$show\n" if $mode eq 'scan' }
    if ($new =~ /\Q$FROM\E/i) { print "REVIEW $f:$n:$show\n" if $mode eq 'scan' }
    $out .= $new;
  }
  if ($mode eq 'fix' && $changed) {
    open my $o, '>:raw', $p or die "write $p: $!"; print $o $out; close $o;
    print "$f\n";
  }
}
