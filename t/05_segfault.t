use strict;
use Net::DNS::Native;
use Test::More;

my $dns = Net::DNS::Native->new;

eval {
	for (1..3) {
		my @fh;
		
		for (1..100) {
			push @fh, $dns->getaddrinfo('localhost');
		}
		
		my $buf;
		sysread($_, $buf, 1) && $dns->get_result($_) for @fh;
	}
};
if (my $err = $@) {
	if ($err =~ /socketpair|pthread/) {
		plan skip_all => $err;
	}
	else {
		fail('No errors');
		diag $err;
	}
}
else {
	pass('No errors');
}

pass('No segfault');
done_testing;
