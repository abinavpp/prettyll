#! /usr/bin/perl

# SPDX-License-Identifier: GPL-2.0+
# Copyright (C) 2020 Abinav Puthan Purayil

use strict;
use warnings;

package Utils;

my $pedantic_level = 0;

sub die_maybe {
  my ($message) = @_;
  if ($pedantic_level > 0) {
    die $message;
  }
}

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

# FIXME: The @indices *must* be consecutive and strictly ascending, currently we
# don't have any requirement for coalescing non-consecutive indices.
sub coalesce_words {
  my ($words, $glue, @indices) = @_;

  if (scalar @indices <= 1) { return; }

  my $new = "";
  foreach my $index (@indices) {
    if ($index <= $#{$words}) {
      $new .= $glue . @$words[$index];
    }
  }

  $$words[$indices[0]] = $new;

  # recall that $#foo = last index of @foo
  splice(@$words, $indices[1], $#indices);
}

sub coalesce_single_nested {
  my ($words, $rpair, $opening) = @_;
  my $closing = $opening + 1;

  for (; $closing <= $#{$words} && $$words[$closing] ne $rpair; $closing++) {}

  if ($closing > $#{$words}) { die_maybe("single_nested not enclosed"); }

  coalesce_words($words, "", $opening..$closing);
}

sub coalesce_nested {
  my ($words, $lpair, $rpair, $opening) = @_;
  my $closing = $opening + 1;
  my $nesting = 1;

  for (; $closing <= $#{$words}; $closing++) {
    if ($$words[$closing] eq $lpair) {
      $nesting++;
    } elsif ($$words[$closing] eq $rpair) {
      $nesting--;
      if ($nesting == 0) { last; }
    }
  }

  if ($closing > $#{$words}) { die_maybe("nested not enclosed"); }

  coalesce_words($words, " ", $opening..$closing);
}

1;
