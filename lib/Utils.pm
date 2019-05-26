#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2019 Abinav Puthan Purayil

use strict;
use warnings;

package Utils;

sub add_to_eqclass {
  my ($eqclass, $entries, $under) = @_;

  foreach my $entry (@$entries) {
    if (!$under) {
      $$eqclass{$entry} = $entry;

    } elsif ($$eqclass{$under}) {
      $$eqclass{$entry} = $$eqclass{$under};

    } else {
      $$eqclass{$entry} = $under;
    }
  }
}

sub coalesce_string_arr {
  my ($arr, $glue, @indices) = @_;

  if (scalar @indices <= 1) { return; }

  my $new = "";
  foreach my $index (@indices) {
    $new .= $glue . @$arr[$index];
  }

  $$arr[$indices[0]] = $new;

  # recall that $#arr = last index of @arr
  splice(@$arr, $indices[1], $#indices);
}

sub coalesce_single_nested {
  my ($words, $rpair, $opening) = @_;
  my $closing = $opening + 1;

  for (; $$words[$closing] ne $rpair && $closing <= $#{$words}; $closing++) {}

  if ($closing > $#{$words}) { die "single_nested not enclosed"; }

  coalesce_string_arr($words, "", $opening..$closing);
}

sub coalesce_nested {
  my ($epilogue_words, $lpair, $rpair, $opening) = @_;
  my $closing = $opening + 1;
  my $nesting = 1;

  for (;$closing <= $#{$epilogue_words}; $closing++) {
    if ($$epilogue_words[$closing] eq $lpair) {
      $nesting++;
    } elsif ($$epilogue_words[$closing] eq $rpair) {
      $nesting--;
      if ($nesting == 0) { last; }
    }
  }

  if ($closing > $#{$epilogue_words}) { die "nested not enclosed"; }

  coalesce_string_arr($epilogue_words, " ", $opening..$closing);
}


1;
