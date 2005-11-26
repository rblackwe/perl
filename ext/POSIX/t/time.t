#!perl -w

use strict;

use Config;
use POSIX;
use Test::More qw(no_plan);

# go to UTC to avoid DST issues around the world when testing
{
    no warnings 'uninitialized';
    $ENV{TZ} = undef;
}

SKIP: {
    # It looks like POSIX.xs claims that only VMS and Mac OS traditional
    # don't have tzset().  A config setting might be helpful.  Win32 actually
    # seems ambiguous
    skip "No tzset()", 2
       if $^O eq "MacOS" || $^O eq "VMS" || $^O eq "cygwin" ||
          $^O eq "MSWin32" || $^O eq "dos" || $^O eq "interix" || 
          $^O eq "openbsd";
    tzset();
    my @tzname = tzname();
    like($tzname[0], qr/[GMT|UTC]/i, "tzset() to GMT/UTC");
    like($tzname[1], qr/[GMT|UTC]/i, "The whole year?");
}

# asctime and ctime...Let's stay below INT_MAX for 32-bits and
# positive for some picky systems.

is(asctime(localtime(0)), ctime(0), "asctime() and ctime() at zero");
is(asctime(localtime(12345678)), ctime(12345678), "asctime() and ctime() at 12345678");

# Careful!  strftime() is locale sensative.  Let's take care of that
my $orig_loc = setlocale(LC_TIME, "C") || die "Cannot setlocale() to C:  $!";
if ($^O eq "MSWin32") {
    is(ctime(0), strftime("%a %b %#d %H:%M:%S %Y\n", localtime(0)),
        "get ctime() equal to strftime()");
} else {
    is(ctime(0), strftime("%a %b %e %H:%M:%S %Y\n", localtime(0)),
        "get ctime() equal to strftime()");
}
setlocale(LC_TIME, $orig_loc) || die "Cannot setlocale() back to orig: $!";

# Hard to test other than to make sure it returns something numeric and < 0
like(clock(), qr/\d*/, "clock() returns a numeric value");
ok(clock() > 0, "...and its greater than zero");

SKIP: {
    skip "No difftime()", 1 if $Config{d_difftime} ne 'define';
    is(difftime(2, 1), 1, "difftime()");
}

SKIP: {
    skip "No mktime()", 1 if $Config{d_mktime} ne 'define';
    my $time = time();
    is(mktime(localtime($time)), $time, "mktime()");
}
