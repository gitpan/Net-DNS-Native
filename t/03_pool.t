use strict;
use Net::DNS::Native;
use Socket;
use IO::Select;
use Test::More;

unless ($Net::DNS::Native::PERL_OK) {
	plan skip_all => "This perl doesn't support threaded libraries";
}

my $ip = inet_aton("google.com");
unless ($ip) {
	plan skip_all => "no DNS access on this computer";
}

my $dns = Net::DNS::Native->new(pool => 3);
my $sel = IO::Select->new();

for my $domain ('google.com', 'google.ru', 'google.cy', 'mail.ru', 'mail.com', 'mail.net') {
	my $sock = $dns->gethostbyname($domain);
	$sel->add($sock);
}

while ($sel->count() > 0) {
	my @ready = $sel->can_read(60);
	ok(@ready > 0, 'resolving took less than 60 sec');
	
	for my $sock (@ready) {
		$sel->remove($sock);
		
		if (my $ip = $dns->get_result($sock)) {
			ok(eval{inet_ntoa($ip)}, 'correct ipv4 address');
		}
	}
}

done_testing;
