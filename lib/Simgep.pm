#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2020 Abinav Puthan Purayil

use strict;
use warnings;

use lib '.';
use Llvm;

package Simgep;

sub transform {
  if (!$Prettyll::opt_simgep) { return; }

  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my $output_ir = "";
  while (my %parsed_obj = Llvm::parse($fh)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }

    if ($parsed_obj{type} eq Llvm::parsed_type_instruction) {
      my $instr_lhs = $parsed_obj{lhs};
      my $instr_name = $parsed_obj{name};
      my @instr_operands = @{$parsed_obj{args}};
      my @words = @{$parsed_obj{words}};

      if ($instr_name eq "getelementptr") {
        $output_ir .= "  $instr_lhs = getelementptr ";

        # add type
        if ($words[3] eq "inbounds") {
          $output_ir .= "$words[6] ";
        } else {
          $output_ir .= "$words[5] ";
        }

        # add operands
        $output_ir .= "$instr_operands[0]\[" . join(', ', @instr_operands[1..$#instr_operands]) . "]\n";
      } else {
        $output_ir .= "$parsed_obj{line}";
      }

    } else {
      $output_ir .= "$parsed_obj{line}";
    }
  }

  seek $fh, 0, 0;
  truncate $input_ll, 0;
  print $fh $output_ir;
}

1;
