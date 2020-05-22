#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2020 Abinav Puthan Purayil

package Demangle;

use strict;
use warnings;

use lib '.';
use Llvm;

sub demangle_if_required {
  my ($line, @symbols) = @_;

  foreach my $symbol (@symbols) {
    if (!$symbol || !Llvm::is_var_or_type_or_comdat($symbol)) {
      next;
    }

    # strip off the @ or % or $
    my $bare_symbol = substr($symbol, 1);

    my $cpp_filt_cmdline = "c++filt -n " . $bare_symbol;
    my $cpp_filt_out = `$cpp_filt_cmdline`; chomp($cpp_filt_out);

    if ($bare_symbol eq $cpp_filt_out) {
      next;
    } else {
      my $demangled = substr($symbol, 0, 1) . '"' .  $cpp_filt_out . '"';

      # \Q quote meta is required since we consider comdat symbols that start
      # with "$".
      $line =~ s/\Q$symbol/$demangled/g;
    }
  }
  return $line;
}

sub transform {
  if (!$Prettyll::opt_demangle) { return; }

  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my $output_ir = "";
  while (my %parsed_obj = Llvm::parse($fh)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }

    my @work_list;
    if ($parsed_obj{lhs}) { push(@work_list, $parsed_obj{lhs}); }
    if ($parsed_obj{name}) { push(@work_list, $parsed_obj{name}); }
    if ($parsed_obj{args}) { push(@work_list, @{$parsed_obj{args}}); }
    $output_ir .= demangle_if_required($parsed_obj{line}, @work_list);
  }

  seek $fh, 0, 0;
  truncate $input_ll, 0;
  print $fh $output_ir;
}

1;
