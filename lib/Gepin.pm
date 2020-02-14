#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2020 Abinav Puthan Purayil

use strict;
use warnings;

use lib '.';
use Llvm;

package Gepin;

sub transform {
  if (!$Prettyll::opt_gepin) { return; }

  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my $output_ir = "";
  while (my %parsed_obj = Llvm::parse($fh)) {
    if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }

    # Print everything outside a function
    $output_ir .= $parsed_obj{line};

    # if function definition
    if ($parsed_obj{type} eq Llvm::parsed_type_function_define_start) {
      my %var_to_gepdim = ();

      # parse function body
      while (%parsed_obj = Llvm::parse($fh)) {
        if ($parsed_obj{type} eq Llvm::parsed_type_eof) { last; }
        my $print_me = "";

        # end of function
        if ($parsed_obj{type} eq Llvm::parsed_type_function_define_end)
          { $output_ir .= $parsed_obj{line}; last; }

        if ($parsed_obj{type} eq Llvm::parsed_type_instruction) {
          my $instr_lhs = $parsed_obj{lhs};
          my $instr_name = $parsed_obj{name};
          my @instr_operands = @{$parsed_obj{args}};
          my @words = @{$parsed_obj{words}};

          if ($instr_name eq "getelementptr") {
            my $gepdim = "gep ";

            # add the type
            if ($words[3] eq "inbounds") {
              $gepdim .= "$words[6] ";
            } else {
              $gepdim .= "$words[5] ";
            }

            # if there's a gep operand, then expand it.
            for (my $i = 0; $i <= $#instr_operands; $i++) {
              if ($var_to_gepdim{$instr_operands[$i]}) {
                $instr_operands[$i] = $var_to_gepdim{$instr_operands[$i]};
              }
            }

            # add the base
            $gepdim .= "$instr_operands[0]";

            # add the indices
            $gepdim .= '[' . join(', ', @instr_operands[1..$#instr_operands]) . ']';

            $var_to_gepdim{$instr_lhs} = "(" . $gepdim . ")";

          } else {
            $print_me = Llvm::substitute_operands(\%parsed_obj, \%var_to_gepdim);
          }

        } else {
          $print_me = $parsed_obj{line};
        }

        $output_ir .= $print_me;
      }
    }
  }

  seek $fh, 0, 0;
  truncate $input_ll, 0;
  print $fh $output_ir;
}

1;
