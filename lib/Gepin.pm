#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

use lib '.';
use Llvm;

package Gepin;

sub transform {
  my ($input_ll) = @_;
  open(my $fh, '+<:encoding(UTF-8)', $input_ll)
    or die "Could not open file '$input_ll' $!";

  my $output_ir = "";
  while (my $line = <$fh>) {

    # Print everything outside a function
    $output_ir .= $line;

    # if function definition
    if ($line =~ /$Llvm::funcdef_regex/) {
      my %var_to_gepdim = ();

      while (my $line = <$fh>) { # start of function
        my $print_me = "";

        if ($line =~ /^\s*?\}\s*?$/) { $output_ir .= $line; last; } # end of function

        if ($line =~ /$Llvm::instr_regex/) {
          # we need to remember the capture-groups since a subsequent regex
          # match might loose it.
          my $instr_lhs = $+{instr_lhs};
          my $instr_name = $+{instr_name};
          # $line = Llvm::substitute_operands($line, \%var_to_gepdim);
          my @instr_operands = Llvm::get_operands($line);

          if ($instr_name eq "getelementptr") {
            my $type = Llvm::get_instr_type($line);

            # Llvm::dump_operands($line);
            # we can't use "[...]" or "<...>" since they are discarded by
            # get_epilogue_words()/get_operands(). Also no spaces since regex
            # sucks
            my $gepdim = "%{$type-\>$instr_operands[0]" .
              "{". join('|', @instr_operands[1..$#instr_operands]) . "}}";

            $var_to_gepdim{$instr_lhs} = $gepdim;
            # $print_me = $line;
            $print_me .= "- $instr_lhs = $gepdim\n";

          } else {
            $print_me = Llvm::substitute_operands($line, \%var_to_gepdim);
          }

          # still print even if it's not an instr_regex
        } else {
          $print_me = $line;
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
