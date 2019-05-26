#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use Data::Dumper;
use Text::Balanced;

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

sub lex_epilogue {
  my ($line) = @_;

  $line =~ s/(, | < | > | \( | \) | \[ | \] | \{ | \} | ")/\ $1\ /xg;
  $line =~ s/^\s+//g;
  my @words = split(/\s+/, $line);

  for (my $i = 0; $i <= ($#words - 1); $i++) {

    # coalesce packed struct (ie. <{...}>) words
    if (($words[$i] eq '<' && $words[$i + 1] eq '{') ||
      ($words[$i] eq '}' && $words[$i + 1] eq '>')) {
      Utils::coalesce_string_arr(\@words, "", $i..($i + 1));
    }

    if ($words[$i] eq '"') {
      Utils::coalesce_single_nested(\@words, '"', $i);

      if ($words[$i - 1] =~ /^(%|@)$/) {
        Utils::coalesce_string_arr(\@words, "", ($i - 1)..$i);
      }
    }

  }
  return @words;
}

sub coalesce_array_typespec {
  my ($epilogue_words, $opening) = @_;
  Utils::coalesce_nested($epilogue_words, '[', ']', $opening);
}

sub coalesce_packed_struct_typespec {
  my ($epilogue_words, $opening) = @_;
  Utils::coalesce_nested($epilogue_words, '<{', '}>', $opening);
}

sub coalesce_struct_typespec {
  my ($epilogue_words, $opening) = @_;
  Utils::coalesce_nested($epilogue_words, '{', '}', $opening);
}

sub coalesce_vector_typespec {
  my ($epilogue_words, $opening) = @_;
  Utils::coalesce_singled_nested($epilogue_words, '>', $opening);
}

sub coalesce_epilogue_words {
  my ($epilogue_words) = (@_);

  for (my $i = 0; $i <= $#{$epilogue_words}; $i++) {

    if ($$epilogue_words[$i] eq '<') {
      coalesce_vector_typespec($epilogue_words, $i);

    } elsif ($$epilogue_words[$i] eq '[') {
      coalesce_array_typespec($epilogue_words, $i);

    } elsif ($$epilogue_words[$i] eq '{') {
      coalesce_struct_typespec($epilogue_words, $i);

    } elsif ($$epilogue_words[$i] eq '<{') {
      coalesce_packed_struct_typespec($epilogue_words, $i);

    } elsif ($$epilogue_words[$i] =~ /^(> | }> | \])$/xg) {
      die "vector/aggregate not enclosed";
    }
  }
}

sub get_epilogue_words {
  my ($line) = @_;

  if ($line =~ /$instr_regex/ || $line =~ /$funcdef_regex/) {
    my $instr_name = $+{instr_name};
    my $epilogue = $+{epilogue};

    # force balanced [] for switch table cases.
    # TODO: handle switch properly
    if ($epilogue =~ /\[$/g) { $epilogue .= ']' }

    # force balanced {} for funcdef
    if ($epilogue =~ /\{$/g) { $epilogue .= '}' }

    # if already computed
    if ($cached_epilogue_words{$epilogue}) {
      return @{$cached_epilogue_words{$epilogue}};
    }

    my @fields = lex_epilogue($epilogue);

    if ($instr_name && $instr_name eq 'phi') {
      if ($fields[0] eq '<') {
        coalesce_vector_typespec(\@fields, 0);

      } elsif ($fields[0] eq '[') {
        coalesce_array_typespec(\@fields, 0);

      } elsif ($fields[0] eq '{') {
        coalesce_struct_typespec(\@fields, 0);

      } elsif ($fields[0] eq '<{') {
        coalesce_packed_struct_typespec(\@fields, 0);
      }

      @{$cached_epilogue_words{$epilogue}} = @fields;
      return @fields;
    }

    coalesce_epilogue_words(\@fields);
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

sub dump_operands {
  my ($line) = @_;
  my @operands;

  @operands = get_operands($line);
  print "In $line";
  print "[" . join(', ', @operands) . "]\n";
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
    # if ($line =~ /$instr_regex/ || $line =~ /$funcdef_regex/) {
      # dump_operands($line);
    # }
  }
}

1;
