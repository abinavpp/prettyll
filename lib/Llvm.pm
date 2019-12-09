#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use Data::Dumper;

no warnings 'experimental::smartmatch';

package Llvm;

# Regexes for parsing (not used anymore)
# -------------------
our $instr_regex = qr/\ *?
  (
    (?<instr_lhs>(%|@).+?)
    \ +?=\ +?
  )?

  (?<instr_name>[\w\.]+)
  \ +

  (?<epilogue>.*)
  $/x;

our $funcdef_regex = qr/^define
  .*?
  (?<func_name>@.+?)

  \(
  (?<epilogue>.+?)
  \{$/x;

our $funcdecl_regex = qr/^declare
  .+?
  (?<func_name>@.+?)

  \(
  (?<epilogue>.+?)
  $/x;

our $typedecl_regex = qr/
  (?<type_name>%.+?)
  \ +?=\ +?
  type\ +?
  .*
  $/x;

# array of globals
my @globals;

# array of user-defined types
my @userdef_types;

# the input .ll file
my $input_ll;

sub is_const {
  my ($var) = @_;
  if ($var =~ /^\-?[0-9]+$/ || $var =~ /^0x[0-9A-F]+$/) {
    return 1;
  }

  return 0;
}

sub is_var {
  my ($var) = @_;

  # Varibles should start with @ or %, followed by some printables and it should
  # not end with a "*" (which would be a type otherwise)
  if ($var =~ /^(%|@).+?$/ && $var !~ /^.+?\*$/) {
    if ($var ~~ @userdef_types) { return 0; }
    return 1;
  }

  return 0;
}

sub is_var_or_type_or_comdat {
  my ($var) = @_;

  if ($var =~ /^(%|@|\$).+?$/) {
    return 1;
  }
  return 0;
}

sub is_global_var {
  my ($var) = @_;
  if (is_var($var) && $var =~ /^@.+?/) {
    return 1;
  }
  return 0;
}

sub coalesce_packed_struct_typespec {
  my ($words, $opening) = @_;
  Utils::coalesce_nested($words, '<{', '}>', $opening);
}

sub coalesce_struct_typespec {
  my ($words, $opening) = @_;
  Utils::coalesce_nested($words, '{', '}', $opening);
}

sub coalesce_vector_typespec {
  my ($words, $opening) = @_;
  Utils::coalesce_single_nested($words, '>', $opening);
}

sub coalesce_array_typespec {
  my ($words, $opening) = @_;

  # Ignore if this is a phi operand.
  if ($opening + 2 < $#{$words} && $$words[$opening + 2] eq ",") {
    return;
  }

  Utils::coalesce_nested($words, '[', ']', $opening);
}

sub lex {
  my ($line) = @_;

  # chop up $line to @words by these delimiters.
  $line =~ s/(, | ; | < | > | \( | \) | \[ | \] | \{ | \} |")/\ $1\ /xg;
  $line =~ s/^\s+//g;
  my @words = split(/\s+/, $line);

  # Coalesce quotes and packed-struct delimiters.
  for (my $i = 0; $i <= ($#words - 1); $i++) {

    # coalesce packed struct (ie. <{...}>) words.
    # [$i + 1] can't go out-of-bounds since $i iterates from 0 to the
    # last-but-first index
    if (($words[$i] eq '<' && $words[$i + 1] eq '{') ||
      ($words[$i] eq '}' && $words[$i + 1] eq '>')) {
      Utils::coalesce_words(\@words, "", $i..($i + 1));
    }

    if ($words[$i] eq '"') {
      Utils::coalesce_single_nested(\@words, '"', $i);

      if ($i > 0 && $words[$i - 1] =~ /^(%|@)$/) {
        Utils::coalesce_words(\@words, "", ($i - 1)..$i);
      }
    }
  }

  # discard comments.
  for (my $i = 0; $i <= $#words; $i++) {
    if ($words[$i] eq ";") {
      splice(@words, -$i);
      last;
    }
  }

  # Coalesce type specifiers.
  for (my $i = 0; $i <= $#words; $i++) {
    if ($words[$i] eq '<') {
      coalesce_vector_typespec(\@words, $i);

    } elsif ($words[$i] eq '[') {
      coalesce_array_typespec(\@words, $i);

    } elsif ($words[$i] eq '{') {
      coalesce_struct_typespec(\@words, $i);

    } elsif ($words[$i] eq '<{') {
      coalesce_packed_struct_typespec(\@words, $i);

    } elsif ($words[$i] =~ /^(> | }> | \])$/xg) {
      Utils::die_maybe("vector/aggregate not enclosed");
    }
  }

  return @words;
}

sub init {
  my ($ll) = @_;
  $input_ll = $ll;
  get_globals();
  get_userdef_types();
}

sub get_args {
  my (@words) = @_;
  my @operands;
  foreach my $word (@words) {
    if (is_var($word) || is_const($word)) {
      push(@operands, $word);
    }
  }
  return @operands;
}

use constant {
  parsed_type_empty => 'empty',
  parsed_type_unknown => 'unknown',
  parsed_type_eof => 'eof',
  parsed_type_instruction => 'instruction',

  parsed_type_type_declare => 'type_declare',

  parsed_type_function_declare => 'function_declare',
  parsed_type_function_define_start => 'function_define_start',
  parsed_type_function_define_end => 'function_define_end'
};

my %cached_parsed_objs;

sub parse {
  my ($fh, $caching_state) = @_;
  my %parsed_obj;

  # enable caching by default
  if (!(defined $caching_state)) {
    $caching_state = 1;
  }

  if (defined(my $line = <$fh>)) {
    # If $line already parsed
    if ($caching_state && $cached_parsed_objs{$line}) {
      return %{$cached_parsed_objs{$line}};
    }

    $parsed_obj{line} = $line;
    my @words = lex($line);
    @{$parsed_obj{words}} = @words;

    # empty line, comment
    if ($#words == -1) {
      $parsed_obj{type} = Llvm::parsed_type_empty;

    # function declaration
    } elsif ($words[0] eq "declare") {
      $parsed_obj{type} = Llvm::parsed_type_function_declare;
      my @func_names = grep { /@.+/ } @words;
      $parsed_obj{name} = $func_names[0];

    # function definition start
    } elsif ($words[0] eq "define") {
      $parsed_obj{type} = Llvm::parsed_type_function_define_start;
      my @func_names = grep { /@.+/ } @words;
      $parsed_obj{name} = $func_names[0];
      @{$parsed_obj{args}} = get_args(@words);
      shift(@{$parsed_obj{args}});

    # function definition end
    } elsif ($words[0] eq "}") {
      $parsed_obj{type} = Llvm::parsed_type_function_define_end;

    # instruction with lhs or type declare
    } elsif ($#words >= 1 && $words[1] eq "=") {
      $parsed_obj{lhs} = $words[0];

      # type declare
      if ($words[2] eq "type") {
        $parsed_obj{type} = Llvm::parsed_type_type_declare;

      # instruction with lhs
      } else {
        $parsed_obj{type} = Llvm::parsed_type_instruction;
        $parsed_obj{name} = $words[2];
        @{$parsed_obj{args}} = get_args(@words);
        shift(@{$parsed_obj{args}});
      }

    # instruction without lhs.
    } elsif ($words[0] =~ /[\w\.]+/) {
      $parsed_obj{type} = Llvm::parsed_type_instruction;
      $parsed_obj{name} = $words[0];
      @{$parsed_obj{args}} = get_args(@words);

    # unknown
    } else {
      $parsed_obj{type} = Llvm::parsed_type_unknown;
      # print STDERR "in line $line\n@words\n";
    }

    if ($caching_state) {
      %{$cached_parsed_objs{$line}} = %parsed_obj;
    }

  } else {
    $parsed_obj{type} = Llvm::parsed_type_eof;
  }

  return %parsed_obj;
}

sub dump_parser {
  my ($ll) = @_;

  open(my $fh, '+<:encoding(UTF-8)', $ll)
    or die "Could not open file '$ll' $!";

  while (my %parsed_obj = parse($fh)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }
    if ($parsed_obj{type} eq Llvm::parsed_type_empty) { next; }
    print "[$parsed_obj{type}] ";
    if ($parsed_obj{name}) { print "name: $parsed_obj{name}, "; }
    if ($parsed_obj{lhs}) { print "lhs: $parsed_obj{lhs}, "; }
    if ($parsed_obj{args}) { print "args: @{$parsed_obj{args}}"; }
    print "\n";
  }
}


sub get_globals {
  # if already computed
  if (@globals) { return @globals; }

  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  # fetch all global declarations
  # See the comments for get_userdef_types to why we disable
  # caching here.
  while (my %parsed_obj = parse($fh, my $caching = 0)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }

    # function declarations
    if ($parsed_obj{type} eq Llvm::parsed_type_function_declare) {
      push(@globals, $parsed_obj{name});

    # for instr of the form "@foo = ..."
    } elsif ($parsed_obj{type} eq Llvm::parsed_type_instruction) {
      if ($parsed_obj{lhs} && is_global_var($parsed_obj{lhs})) {
        push(@globals, $parsed_obj{lhs});
      }
    }
  }

  return @globals;
}

sub get_userdef_types {
  # if already computed
  if (@userdef_types) { return @userdef_types; }

  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  # disable caching since userdef_type parsing should'nt
  # "misinform" future parsing by caching ignorant results.
  while (my %parsed_obj = parse($fh, my $caching = 0)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }

    # type declarations
    if ($parsed_obj{type} eq Llvm::parsed_type_type_declare) {
      push(@userdef_types, $parsed_obj{lhs});
    }
  }

  return @userdef_types;
}

sub substitute_operands {
  my ($parsed_obj, $var_hash) = @_;

  my $instr = $$parsed_obj{line};
  my @instr_operands = @{$$parsed_obj{args}};

  foreach my $operand (@instr_operands) {
    if ($$var_hash{$operand}) {
      $instr =~ s/$operand/$$var_hash{$operand}/g;
    }
  }

  return $instr;
}

1;
