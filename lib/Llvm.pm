#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use Data::Dumper;
use Text::Balanced;

no warnings 'experimental::smartmatch';

package Llvm;

# Regexes for parsing
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



# Cached data for reuse
# ---------------------

# array globals
my @globals;

# array of user-defined types
my @userdef_types;

# the input .ll file
my $input_ll;

# map of epilogue-of-line -> it's words
my %cached_epilogue_words;

# map of epilogue-of-line -> it's operands
my %cached_epilogue_operands;



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

sub get_epilogue_words {
  my ($line) = @_;

  if ($line =~ /$instr_regex/ || $line =~ /$funcdef_regex/) {
    my $instr_name = $+{instr_name};
    my $epilogue = $+{epilogue};

    # if already computed
    if ($cached_epilogue_words{$epilogue}) {
      return @{$cached_epilogue_words{$epilogue}};
    }

    my @fields = lex($epilogue);

    @{$cached_epilogue_words{$epilogue}} = @fields;
    return @fields;
  }
}

sub get_operands {
  my ($line) = @_;
  my @operands;

  if ($line =~ /$instr_regex/ || $line =~ /$funcdef_regex/) {
    my $epilogue = $+{epilogue};

    # if already computed
    if ($cached_epilogue_operands{$epilogue}) {
      return @{$cached_epilogue_operands{$epilogue}};
    }

    my @epilogue_words = get_epilogue_words($line);

    my $i = 0;
    foreach my $epilogue_word (@epilogue_words) {
      if (is_var($epilogue_word) || is_const($epilogue_word)) {
        $operands[$i++] = $epilogue_word;
      }
    }
    @{$cached_epilogue_operands{$epilogue}} = @operands;
  }


  return @operands;
}

sub get_instr_type {
  my ($line) = @_;
  if ($line =~ /$instr_regex/) {
    if ($+{instr_name} ne "getelementptr") { die "get_instr_type not supported for $+{instr_name}"; }

    my @epilogue_words = get_epilogue_words($line);
    if ($epilogue_words[0] eq "inbounds") { return $epilogue_words[1]; }
    return $epilogue_words[0];
  }
}

sub substitute_operands {
  my ($instr, $var_hash) = @_;

  my @instr_operands = get_operands($instr);
  foreach my $operand (@instr_operands) {
    # iff it's a valid operand (the get_operads might catch a BB
    # defintion's comment for preds = %<something>)
    if ($$var_hash{$operand}) {
      $instr =~ s/$operand/$$var_hash{$operand}/g;
    }
  }

  return $instr;
}

sub get_globals {
  # if already computed
  if (@globals) { return @globals; }

  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  # fetch all global declarations
  while (my $line = <$fh>) {
    # function declarations
    if ($line =~ /$Llvm::funcdecl_regex/) {
      push(@globals, $+{func_name});

      # for instr of the form "@foo = ..."
    } elsif ($line =~ /$Llvm::instr_regex/) {
      if ($+{instr_lhs} && Llvm::is_global_var($+{instr_lhs})) {
        push(@globals, $+{instr_lhs});
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

  while (my $line = <$fh>) {
    # function declarations
    if ($line =~ /$Llvm::typedecl_regex/) {
      push(@userdef_types, $+{type_name});
    }
  }

  return @userdef_types;
}

sub init {
  my ($ll) = @_;
  $input_ll = $ll;
  get_globals();
  get_userdef_types();

  # calculate and cache in all the epilogue_words
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  while (my $line = <$fh>) {
    get_epilogue_words($line);
  }
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

sub parse {
  my ($fh) = @_;
  my %parsed_obj;

  if (defined(my $line = <$fh>)) {
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
    } elsif (is_var($words[0]) && $words[1] eq "=") {
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
      print "@words\n";
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
    if ($parsed_obj{type} eq Llvm::parsed_type_empty) { next; }
    print "[$parsed_obj{type}] ";
    if ($parsed_obj{name}) { print "name: $parsed_obj{name}, "; }
    if ($parsed_obj{lhs}) { print "lhs: $parsed_obj{lhs}, "; }
    if ($parsed_obj{args}) { print "args: @{$parsed_obj{args}}"; }
    print "\n";
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }
  }
}

1;
