#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use lib '.';
use Llvm;
use Utils;

package Simvar;

sub transform {
  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my %var_eqclass; my %globvar_eqclass;
  my @globals = Llvm::get_globals();
  foreach my $global(@globals) {
    Utils::add_to_eqclass(\%globvar_eqclass, [$global]);
  }

  my $output_ir = "";
  while (my $line = <$fh>) {

    # Print everything outside a function
    $output_ir .= $line;

    # if function definition
    if ($line =~ /$Llvm::funcdef_regex/) {
      # reset the equivalence class to only have globals since we are in a
      # new function
      %var_eqclass = %globvar_eqclass;

      my $iteration_num = 0;
      my $tell_func_begin = tell($fh);

      while (my $line = <$fh> || die "malformed function!") { # start of function
        my $print_me = "";

        # end of function
        if ($line =~ /^\s*?\}\s*?$/) {
          if ($iteration_num == 0) {
            $iteration_num++;
            seek($fh, $tell_func_begin, 0);
            next;
          } elsif ($iteration_num == 1) {
            $output_ir .= $line;
            last;
          }
        }

        if ($line =~ /$Llvm::instr_regex/) {
          # we need to remember the capture-groups since a subsequent regex
          # match might loose it.
          my $instr_lhs = $+{instr_lhs};
          my $instr_name = $+{instr_name};
          my @instr_operands = Llvm::get_operands($line);

          # if trivial ("skippable") instr, ie cast/load instruction with a
          # variable operand. There are constant casts (like zext 0 to i64),
          # which are treated as non-trivial instr with lhs.
          # TODO: maybe add trunc ?
          if ($instr_name =~ /(bitcast | load | sext | zext | inttoptr)/x &&
            !Llvm::is_const($instr_operands[0])) {

            # TODO: handle load (bitcast (gep ... )) kinds

            # A use of a var in a non-PHI inst can never "lexically" dominate it's
            # def in a valid llvm-ir, so the $var_eqclass{$operands[0]} cannot be
            # null in this case.
            Utils::add_to_eqclass(\%var_eqclass, [$instr_lhs], $instr_operands[0]);
            # skip printing this line

          # if non-trivial instr without lhs
          } elsif (!$instr_lhs) {
            # then substitue operands with it's eqclass's parent
            $print_me = 
              Llvm::substitute_operands($line, \%var_eqclass);
                
          # if non-trivial instr with lhs
          } else {
            # set the eqclass parent for lhs as itself.
            Utils::add_to_eqclass(\%var_eqclass, [$instr_lhs]);

            # then substitue operands with it's eqclass's parent
            $print_me = 
              Llvm::substitute_operands($line, \%var_eqclass);
          }

        # still print even if it's not an instr_regex
        } else {
          $print_me = $line;
        }

        if ($iteration_num == 1) { $output_ir .= $print_me; }
      } # end of function (or malformed function)
    }
  }

  seek $fh, 0, 0;
  truncate $input_ll, 0;
  print $fh $output_ir;
}

1;
