#!/usr/bin/perl

use strict;

use Getopt::Long;
use Pod::Usage;

use File::Find ();
use File::Basename 'basename','dirname';
use Bio::Graphics::Browser2;
use Bio::Graphics::Browser2::Util 'shellwords';
use POSIX 'ENOTEMPTY';
use CGI::Session;

my ($man,$help,$verbose) = (0,0,0);
GetOptions(
    'help|?' => \$help,
    'man'    => \$man,
    'verbose'=> \$verbose,
    ) or pod2usage(2);
pod2usage(1)           if $help;
pod2usage(-verbose=>2) if $man;

# for the convenience of &wanted calls, including -eval statements:
use vars qw/*name *dir *prune/;
*name   = *File::Find::name;
*dir    = *File::Find::dir;
*prune  = *File::Find::prune;

use constant DEFAULT_MASTER => 'GBrowse.conf';
use constant SECS_PER_DAY   => 60*60*24;

my $conf_dir  = Bio::Graphics::Browser2->config_base;
my $conf_file = $ENV{GBROWSE_MASTER} || DEFAULT_MASTER;
my $globals   = Bio::Graphics::Browser2->new(File::Spec->catfile($conf_dir,
								$conf_file)
    ) or die "Couldn't read globals";

my $tmpdir        = $globals->tmpdir();
my $cache_dir     = $globals->cache_dir;
my $locks_dir     = $globals->session_locks;
my $images_dir    = $globals->tmpimage_dir;
my $user_dir      = $globals->user_dir();
my $uploads_db    = $globals->user_account_db;

my $cache_secs   = $globals->time2sec($globals->cache_time);
my $uploads_secs = $globals->time2sec($globals->upload_time);

logit("***",scalar localtime,basename($0),"starting ***\n");

####################################
# first we clean up expired sessions
####################################

my $remember_settings_time = $globals->remember_settings_time;

logit("Expiring sessions older than $remember_settings_time...");
my $dsn     = $globals->code_setting(general=>'session driver');
my %dsn     = shellwords($globals->code_setting(general=>'session args'));
my $rst     = $globals->time2sec($remember_settings_time);
my $now     = time();
my $deleted = 0;
CGI::Session->find($dsn,
		   sub {
		       my $session = shift;
		       return if $session->is_empty;
		       return if $session->atime + $rst > $now;
		       verbose("session ",$session->id," deleted\n");
		       $session->delete();
		       $session->flush();
		       $deleted++;
		       
		   },\%dsn);
logit("$deleted sessions deleted.\n");

############################################
# now we remove old cache files and userdata
############################################

my ($files,$directories) = (0,0);
my $wanted = sub {
    my ($dev,$ino,$mode,$nlink,$uid,$gid,
	$rdev,$size,$atime,$mtime,$ctime) = stat($_); 

    next if $name =~ m!$tmpdir/[^/]+$!; # don't remove toplevel!
    next if $name eq $tmpdir;

    my $is_userdata = $name =~ m/^$user_dir/;

    if (-d _ ) { # attempt to remove directories - will have no effect unless empty
	if (rmdir($name)) {
	    verbose("rmdir $name\n");
	    $directories++;
	} else {
	    warn "couldn't rmdir $name: $!\n" unless $!==ENOTEMPTY;
	}
	return;
    }

    my $secs = $name =~ m/^($cache_dir|$locks_dir|$images_dir)/  ? $cache_secs
	      :$is_userdata                                      ? $uploads_secs
	      :0;
    return unless $secs;
    my $time = $is_userdata ? -A _ : -M _;

    my $days = $secs/SECS_PER_DAY;

    return unless -f _ && $time > $days;
    if (unlink($name)) {
	$files++;
	verbose("unlinked $name\n");
    } else {
	warn "couldn't unlink $name: $!\n";
    }
};


# Traverse desired filesystems
logit("Deleting cache files and directories...");
File::Find::finddepth( {wanted=>$wanted},  $tmpdir);
logit("Deleting unused user uploads olderthan $uploads_secs seconds (see \"expire uploads\" option in GBrowse.conf)...");
File::Find::finddepth( {wanted=>$wanted},  $user_dir);
logit("Deleted $directories directories and $files files.\n");
if ($uploads_db) {
    logit("Cleaning uploads db...");
    clean_uploads();
}

logit("*** ",scalar localtime,"$0 done ***\n\n");
exit 0;

sub clean_uploads {
    eval {require DBI; 1} or return;

    my $db = DBI->connect($globals->user_account_db) or return;
    my $query = $db->prepare('select sessionid,data_source,path,$trackid from uploads,session where uploads.userid=session.userid') or return;
    $query->execute or return;

    my %flag_for_deletion;
    while (my ($sessionid,$dsn,$path,$trackid) = $query->fetchrow_array) {
	my $full_path = "$user_dir/$dsn/$path";
	next if -e $full_path;
	$flag_for_deletion{$trackid}++;
    }

    my @delete = keys %flag_for_deletion or return;
    my $to_remove = join ',',map {"'$_'"}@delete;
    logit("Deleting ".scalar @delete." dangling uploads");
    $db->do("delete from uploads where trackid in ($to_remove)") or warn $db->errstr;
}

sub verbose {
    my @mess = @_;
    return unless $verbose;
    print "   @mess";
}

sub logit {
    my @mess = @_;
    print "@mess";
}

__END__


=head1 NAME

gbrowse_clean.pl - Clean up sessions and other temporary gbrowse2 files

=head1 SYNOPSIS

From the command line:

 sudo -u www-data gbrowse_clean.pl

Replace "www-data" with the web server account name on your system.

To run automatically under cron, create a crontab file for the web
server user that contains a line like the following:

 # m h  dom mon dow   command
 5 0  *  *  /usr/bin/gbrowse_clean.pl >>/var/log/gbrowse2/gbrowse_clean.log

=head1 OPTIONS

=over 4

=item B<-verbose>

Report actions verbosely, printing out each session, file and
directory deleted.

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=back

=head1 DESCRIPTION

GBrowse2 generates a number of temporary files during its
operations. These files include session data, data cache files, and
temporary image files, as well as user upload data from custom tracks.

This script expires these temporary files, releasing unneeded
space. The script honors the following options from the GBrowse.conf
master configuration file:

 Name                   Default Description
 ----                   ------- -----------
 exire session          1M      How long to keep session data
 expire cache           2h      How long to keep cache data
 expire uploads         6w      How long to keep user track data

Time intervals are indicated using a count and a unit:

 Suffix     Time Unit
 ------     ---------
  s         seconds
  m         minutes
  h         hours
  d         days
  w         weeks
  M         months
  y         years

B<expire session> controls how long before user session data
expires. Once a session expires, the user's saved settings, such as
his preferred data source, track visibility settings, and custom track
uploads are purged. The expiration interval is measured since the last
time the user I<accessed> his session, so simply loading a region in
the browser without changing settings is sufficient to prevent a
session from expiring.

B<expire cache> controls how long before cached track data is purged
from the system. Caching for up to a few hours increases performance
because users frequently reload the same region. Caching for longer
periods increases the time between updating the database and tracks
displaying those changes.

B<expire uploads> controls how long to keep user uploaded data for
custom tracks on disk. It makes sense to keep it on disk for as long
or longer than the session. Even if the user's session expires, he can
still get at the uploaded data if he bookmarked his session or shared
the uploaded track at any point.

This script should be run periodically, ideally under cron. Once per
day should be adequate for most uses, but heavily-used sites may wish
to run the script more frequently. It is important to run the script
under the same user account as the web server; otherwise the script
will be unable to delete the files created by the web server user
during gbrowse execution. B<Do not run this script as root.>

=head1 AUTHOR

Lincoln D. Stein <lincoln.stein@gmail.com>
Copyright 2009 Ontario Institute for Cancer Research

This script is available under either the GNU General Public License
or the Perl Artistic License version 2.0. See LICENSE in the GBrowse
source code distribution for details.

=head1 SEE ALSO

L<http://gmod.org/wiki/GBrowse_2.0_HOWTO>



