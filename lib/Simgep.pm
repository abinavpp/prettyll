#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use lib '.';
use Llvm;

package Simgep;

sub transform {
  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my $output_ir = "";
  while (my $line = <$fh>) {
    if ($line =~ /$Llvm::instr_regex/) {
      my $instr_name = $+{instr_name};

      if ($instr_name eq "getelementptr") {
        my $instr_lhs = $+{instr_lhs};
        my @instr_operands = Llvm::get_operands($line);
        $output_ir .= "  $instr_lhs = getelementptr " . Llvm::get_instr_type($line) .
        " $instr_operands[0]\[" . join(', ', @instr_operands[1..$#instr_operands]) . "]\n";
      } else {
        $output_ir .= "$line";
      }

    } else {
      $output_ir .= "$line";
    }
  }

  seek $fh, 0, 0;
  truncate $input_ll, 0;
  print $fh $output_ir;
}

1;
