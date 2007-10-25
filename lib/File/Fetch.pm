package File::Fetch;

use strict;
use FileHandle;
use File::Copy;
use File::Spec;
use File::Spec::Unix;
use File::Basename              qw[dirname];

use Cwd                         qw[cwd];
use Carp                        qw[carp];
use IPC::Cmd                    qw[can_run run];
use File::Path                  qw[mkpath];
use Params::Check               qw[check];
use Module::Load::Conditional   qw[can_load];
use Locale::Maketext::Simple    Style => 'gettext';

use vars    qw[ $VERBOSE $PREFER_BIN $FROM_EMAIL $USER_AGENT
                $BLACKLIST $METHOD_FAIL $VERSION $METHODS
                $FTP_PASSIVE $TIMEOUT $DEBUG $WARN
            ];

use constant QUOTE  => do { $^O eq 'MSWin32' ? q["] : q['] };            
            

$VERSION        = '0.12';
$PREFER_BIN     = 0;        # XXX TODO implement
$FROM_EMAIL     = 'File-Fetch@example.com';
$USER_AGENT     = 'File::Fetch/$VERSION';
$BLACKLIST      = [qw|ftp|];
$METHOD_FAIL    = { };
$FTP_PASSIVE    = 1;
$TIMEOUT        = 0;
$DEBUG          = 0;
$WARN           = 1;

### methods available to fetch the file depending on the scheme
$METHODS = {
    http    => [ qw|lwp wget curl lynx| ],
    ftp     => [ qw|lwp netftp wget curl ncftp ftp| ],
    file    => [ qw|lwp file| ],
    rsync   => [ qw|rsync| ]
};

### silly warnings ###
local $Params::Check::VERBOSE               = 1;
local $Params::Check::VERBOSE               = 1;
local $Module::Load::Conditional::VERBOSE   = 0;
local $Module::Load::Conditional::VERBOSE   = 0;

### see what OS we are on, important for file:// uris ###
use constant ON_UNIX        => ($^O ne 'MSWin32' and
                                $^O ne 'MacOS');

=pod

=head1 NAME

File::Fetch - A generic file fetching mechanism

=head1 SYNOPSIS

    use File::Fetch;

    ### build a File::Fetch object ###
    my $ff = File::Fetch->new(uri => 'http://some.where.com/dir/a.txt');

    ### fetch the uri to cwd() ###
    my $where = $ff->fetch() or die $ff->error;

    ### fetch the uri to /tmp ###
    my $where = $ff->fetch( to => '/tmp' );

    ### parsed bits from the uri ###
    $ff->uri;
    $ff->scheme;
    $ff->host;
    $ff->path;
    $ff->file;

=head1 DESCRIPTION

File::Fetch is a generic file fetching mechanism.

It allows you to fetch any file pointed to by a C<ftp>, C<http>,
C<file>, or C<rsync> uri by a number of different means.

See the C<HOW IT WORKS> section further down for details.

=head1 ACCESSORS

A C<File::Fetch> object has the following accessors

=over 4

=item $ff->uri

The uri you passed to the constructor

=item $ff->scheme

The scheme from the uri (like 'file', 'http', etc)

=item $ff->host

The hostname in the uri, will be empty for a 'file' scheme.

=item $ff->path

The path from the uri, will be at least a single '/'.

=item $ff->file

The name of the remote file. For the local file name, the
result of $ff->output_file will be used. 

=cut


##########################
### Object & Accessors ###
##########################

{
    ### template for new() and autogenerated accessors ###
    my $Tmpl = {
        scheme          => { default => 'http' },
        host            => { default => 'localhost' },
        path            => { default => '/' },
        file            => { required => 1 },
        uri             => { required => 1 },
        _error_msg      => { no_override => 1 },
        _error_msg_long => { no_override => 1 },
    };
    
    for my $method ( keys %$Tmpl ) {
        no strict 'refs';
        *$method = sub {
                        my $self = shift;
                        $self->{$method} = $_[0] if @_;
                        return $self->{$method};
                    }
    }
    
    sub _create {
        my $class = shift;
        my %hash  = @_;
        
        my $args = check( $Tmpl, \%hash ) or return;
        
        bless $args, $class;
    
        if( lc($args->scheme) ne 'file' and not $args->host ) {
            return File::Fetch->_error(loc(
                "Hostname required when fetching from '%1'",$args->scheme));
        }
        
        for (qw[path file]) {
            unless( $args->$_ ) {
                return File::Fetch->_error(loc("No '%1' specified",$_));
            }
        }
        
        return $args;
    }    
}

=item $ff->output_file

The name of the output file. This is the same as $ff->file,
but any query parameters are stripped off. For example:

    http://example.com/index.html?x=y

would make the output file be C<index.html> rather than 
C<index.html?x=y>.

=back

=cut

sub output_file {
    my $self = shift;
    my $file = $self->file;
    
    $file =~ s/\?.*$//g;
    
    return $file;
}

### XXX do this or just point to URI::Escape?
# =head2 $esc_uri = $ff->escaped_uri
# 
# =cut
# 
# ### most of this is stolen straight from URI::escape
# {   ### Build a char->hex map
#     my %escapes = map { chr($_) => sprintf("%%%02X", $_) } 0..255;
# 
#     sub escaped_uri {
#         my $self = shift;
#         my $uri  = $self->uri;
# 
#         ### Default unsafe characters.  RFC 2732 ^(uric - reserved)
#         $uri =~ s/([^A-Za-z0-9\-_.!~*'()])/
#                     $escapes{$1} || $self->_fail_hi($1)/ge;
# 
#         return $uri;
#     }
# 
#     sub _fail_hi {
#         my $self = shift;
#         my $char = shift;
#         
#         $self->_error(loc(
#             "Can't escape '%1', try using the '%2' module instead", 
#             sprintf("\\x{%04X}", ord($char)), 'URI::Escape'
#         ));            
#     }
# 
#     sub output_file {
#     
#     }
#     
#     
# }

=head1 METHODS

=head2 $ff = File::Fetch->new( uri => 'http://some.where.com/dir/file.txt' );

Parses the uri and creates a corresponding File::Fetch::Item object,
that is ready to be C<fetch>ed and returns it.

Returns false on failure.

=cut

sub new {
    my $class = shift;
    my %hash  = @_;

    my ($uri);
    my $tmpl = {
        uri => { required => 1, store => \$uri },
    };

    check( $tmpl, \%hash ) or return;

    ### parse the uri to usable parts ###
    my $href    = __PACKAGE__->_parse_uri( $uri ) or return;

    ### make it into a FFI object ###
    my $ff      = File::Fetch->_create( %$href ) or return;


    ### return the object ###
    return $ff;
}

### parses an uri to a hash structure:
###
### $class->_parse_uri( 'ftp://ftp.cpan.org/pub/mirror/index.txt' )
###
### becomes:
###
### $href = {
###     scheme  => 'ftp',
###     host    => 'ftp.cpan.org',
###     path    => '/pub/mirror',
###     file    => 'index.html'
### };
###
sub _parse_uri {
    my $self = shift;
    my $uri  = shift or return;

    my $href = { uri => $uri };

    ### find the scheme ###
    $uri            =~ s|^(\w+)://||;
    $href->{scheme} = $1;

    ### file:// paths have no host ###
    if( $href->{scheme} eq 'file' ) {
        $href->{path} = $uri;
        $href->{host} = '';

    } else {
        @{$href}{qw|host path|} = $uri =~ m|([^/]*)(/.*)$|s;
    }

    ### split the path into file + dir ###
    {   my @parts = File::Spec::Unix->splitpath( delete $href->{path} );
        $href->{path} = $parts[1];
        $href->{file} = $parts[2];
    }


    return $href;
}

=head2 $ff->fetch( [to => /my/output/dir/] )

Fetches the file you requested. By default it writes to C<cwd()>,
but you can override that by specifying the C<to> argument.

Returns the full path to the downloaded file on success, and false
on failure.

=cut

sub fetch {
    my $self = shift or return;
    my %hash = @_;

    my $to;
    my $tmpl = {
        to  => { default => cwd(), store => \$to },
    };

    check( $tmpl, \%hash ) or return;

    ### create the path if it doesn't exist yet ###
    unless( -d $to ) {
        eval { mkpath( $to ) };

        return $self->_error(loc("Could not create path '%1'",$to)) if $@;
    }

    ### set passive ftp if required ###
    local $ENV{FTP_PASSIVE} = $FTP_PASSIVE;

    ###
    my $out_to = File::Spec->catfile( $to, $self->output_file );
    for my $method ( @{ $METHODS->{$self->scheme} } ) {
        my $sub =  '_'.$method.'_fetch';

        unless( __PACKAGE__->can($sub) ) {
            $self->_error(loc("Cannot call method for '%1' -- WEIRD!",
                        $method));
            next;
        }

        ### method is blacklisted ###
        next if grep { lc $_ eq $method } @$BLACKLIST;

        ### method is known to fail ###
        next if $METHOD_FAIL->{$method};

        ### there's serious issues with IPC::Run and quoting of command
        ### line arguments. using quotes in the wrong place breaks things,
        ### and in the case of say, 
        ### C:\cygwin\bin\wget.EXE --quiet --passive-ftp --output-document
        ### "index.html" "http://www.cpan.org/index.html?q=1&y=2"
        ### it doesn't matter how you quote, it always fails.
        local $IPC::Cmd::USE_IPC_RUN = 0;
        
        if( my $file = $self->$sub( 
                        to => $out_to
        )){

            unless( -e $file && -s _ ) {
                $self->_error(loc("'%1' said it fetched '%2', ".
                     "but it was not created",$method,$file));

                ### mark the failure ###
                $METHOD_FAIL->{$method} = 1;

                next;

            } else {

                my $abs = File::Spec->rel2abs( $file );
                return $abs;
            }
        }
    }


    ### if we got here, we looped over all methods, but we weren't able
    ### to fetch it.
    return;
}

########################
### _*_fetch methods ###
########################

### LWP fetching ###
sub _lwp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### modules required to download with lwp ###
    my $use_list = {
        LWP                 => '0.0',
        'LWP::UserAgent'    => '0.0',
        'HTTP::Request'     => '0.0',
        'HTTP::Status'      => '0.0',
        URI                 => '0.0',

    };

    if( can_load(modules => $use_list) ) {

        ### setup the uri object
        my $uri = URI->new( File::Spec::Unix->catfile(
                                    $self->path, $self->file
                        ) );

        ### special rules apply for file:// uris ###
        $uri->scheme( $self->scheme );
        $uri->host( $self->scheme eq 'file' ? '' : $self->host );
        $uri->userinfo("anonymous:$FROM_EMAIL") if $self->scheme ne 'file';

        ### set up the useragent object
        my $ua = LWP::UserAgent->new();
        $ua->timeout( $TIMEOUT ) if $TIMEOUT;
        $ua->agent( $USER_AGENT );
        $ua->from( $FROM_EMAIL );
        $ua->env_proxy;

        my $res = $ua->mirror($uri, $to) or return;

        ### uptodate or fetched ok ###
        if ( $res->code == 304 or $res->code == 200 ) {
            return $to;

        } else {
            return $self->_error(loc("Fetch failed! HTTP response: %1 %2 [%3]",
                        $res->code, HTTP::Status::status_message($res->code),
                        $res->status_line));
        }

    } else {
        $METHOD_FAIL->{'lwp'} = 1;
        return;
    }
}

### Net::FTP fetching
sub _netftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### required modules ###
    my $use_list = { 'Net::FTP' => 0 };

    if( can_load( modules => $use_list ) ) {

        ### make connection ###
        my $ftp;
        my @options = ($self->host);
        push(@options, Timeout => $TIMEOUT) if $TIMEOUT;
        unless( $ftp = Net::FTP->new( @options ) ) {
            return $self->_error(loc("Ftp creation failed: %1",$@));
        }

        ### login ###
        unless( $ftp->login( anonymous => $FROM_EMAIL ) ) {
            return $self->_error(loc("Could not login to '%1'",$self->host));
        }

        ### set binary mode, just in case ###
        $ftp->binary;

        ### create the remote path 
        ### remember remote paths are unix paths! [#11483]
        my $remote = File::Spec::Unix->catfile( $self->path, $self->file );

        ### fetch the file ###
        my $target;
        unless( $target = $ftp->get( $remote, $to ) ) {
            return $self->_error(loc("Could not fetch '%1' from '%2'",
                        $remote, $self->host));
        }

        ### log out ###
        $ftp->quit;

        return $target;

    } else {
        $METHOD_FAIL->{'netftp'} = 1;
        return;
    }
}

### /bin/wget fetch ###
sub _wget_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### see if we have a wget binary ###
    if( my $wget = can_run('wget') ) {

        ### no verboseness, thanks ###
        my $cmd = [ $wget, '--quiet' ];

        ### if a timeout is set, add it ###
        push(@$cmd, '--timeout=' . $TIMEOUT) if $TIMEOUT;

        ### run passive if specified ###
        push @$cmd, '--passive-ftp' if $FTP_PASSIVE;

        ### set the output document, add the uri ###
        push @$cmd, '--output-document', 
                    ### DO NOT quote things for IPC::Run, it breaks stuff.
                    $IPC::Cmd::USE_IPC_RUN
                        ? ($to, $self->uri)
                        : (QUOTE. $to .QUOTE, QUOTE. $self->uri .QUOTE);

        ### shell out ###
        my $captured;
        unless(run( command => $cmd, 
                    buffer  => \$captured, 
                    verbose => $DEBUG  
        )) {
            ### wget creates the output document always, even if the fetch
            ### fails.. so unlink it in that case
            1 while unlink $to;
            
            return $self->_error(loc( "Command failed: %1", $captured || '' ));
        }

        return $to;

    } else {
        $METHOD_FAIL->{'wget'} = 1;
        return;
    }
}


### /bin/ftp fetch ###
sub _ftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### see if we have a ftp binary ###
    if( my $ftp = can_run('ftp') ) {

        my $fh = FileHandle->new;

        local $SIG{CHLD} = 'IGNORE';

        unless ($fh->open("|$ftp -n")) {
            return $self->_error(loc("%1 creation failed: %2", $ftp, $!));
        }

        my @dialog = (
            "lcd " . dirname($to),
            "open " . $self->host,
            "user anonymous $FROM_EMAIL",
            "cd /",
            "cd " . $self->path,
            "binary",
            "get " . $self->file . " " . $self->output_file,
            "quit",
        );

        foreach (@dialog) { $fh->print($_, "\n") }
        $fh->close or return;

        return $to;
    }
}

### lynx is stupid - it decompresses any .gz file it finds to be text
### use /bin/lynx to fetch files
sub _lynx_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### see if we have a lynx binary ###
    if( my $lynx = can_run('lynx') ) {

        unless( IPC::Cmd->can_capture_buffer ) {
            $METHOD_FAIL->{'lynx'} = 1;

            return $self->_error(loc( 
                "Can not capture buffers. Can not use '%1' to fetch files",
                'lynx' ));
        }            

        ### write to the output file ourselves, since lynx ass_u_mes to much
        my $local = FileHandle->new(">$to")
                        or return $self->_error(loc(
                            "Could not open '%1' for writing: %2",$to,$!));

        ### dump to stdout ###
        my $cmd = [
            $lynx,
            '-source',
            "-auth=anonymous:$FROM_EMAIL",
        ];

        push @$cmd, "-connect_timeout=$TIMEOUT" if $TIMEOUT;

        ### DO NOT quote things for IPC::Run, it breaks stuff.
        push @$cmd, $IPC::Cmd::USE_IPC_RUN
                        ? $self->uri
                        : QUOTE. $self->uri .QUOTE;


        ### shell out ###
        my $captured;
        unless(run( command => $cmd,
                    buffer  => \$captured,
                    verbose => $DEBUG )
        ) {
            return $self->_error(loc("Command failed: %1", $captured || ''));
        }

        ### print to local file ###
        ### XXX on a 404 with a special error page, $captured will actually
        ### hold the contents of that page, and make it *appear* like the
        ### request was a success, when really it wasn't :(
        ### there doesn't seem to be an option for lynx to change the exit
        ### code based on a 4XX status or so.
        ### the closest we can come is using --error_file and parsing that,
        ### which is very unreliable ;(
        $local->print( $captured );
        $local->close or return;

        return $to;

    } else {
        $METHOD_FAIL->{'lynx'} = 1;
        return;
    }
}

### use /bin/ncftp to fetch files
sub _ncftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### we can only set passive mode in interactive sesssions, so bail out
    ### if $FTP_PASSIVE is set
    return if $FTP_PASSIVE;

    ### see if we have a ncftp binary ###
    if( my $ncftp = can_run('ncftp') ) {

        my $cmd = [
            $ncftp,
            '-V',                   # do not be verbose
            '-p', $FROM_EMAIL,      # email as password
            $self->host,            # hostname
            dirname($to),           # local dir for the file
                                    # remote path to the file
            ### DO NOT quote things for IPC::Run, it breaks stuff.
            $IPC::Cmd::USE_IPC_RUN
                        ? File::Spec::Unix->catdir( $self->path, $self->file )
                        : QUOTE. File::Spec::Unix->catdir( 
                                        $self->path, $self->file ) .QUOTE
            
        ];

        ### shell out ###
        my $captured;
        unless(run( command => $cmd,
                    buffer  => \$captured,
                    verbose => $DEBUG )
        ) {
            return $self->_error(loc("Command failed: %1", $captured || ''));
        }

        return $to;

    } else {
        $METHOD_FAIL->{'ncftp'} = 1;
        return;
    }
}

### use /bin/curl to fetch files
sub _curl_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    if (my $curl = can_run('curl')) {

        ### these long opts are self explanatory - I like that -jmb
	    my $cmd = [ $curl ];

	    push(@$cmd, '--connect-timeout', $TIMEOUT) if $TIMEOUT;

	    push(@$cmd, '--silent') unless $DEBUG;

        ### curl does the right thing with passive, regardless ###
    	if ($self->scheme eq 'ftp') {
    		push(@$cmd, '--user', "anonymous:$FROM_EMAIL");
    	}

        ### curl doesn't follow 302 (temporarily moved) etc automatically
        ### so we add --location to enable that.
        push @$cmd, '--fail', '--location', '--output', 
                    ### DO NOT quote things for IPC::Run, it breaks stuff.
                    $IPC::Cmd::USE_IPC_RUN
                        ? ($to, $self->uri)
                        : (QUOTE. $to .QUOTE, QUOTE. $self->uri .QUOTE);

        my $captured;
        unless(run( command => $cmd,
                    buffer  => \$captured,
                    verbose => $DEBUG )
        ) {

            return $self->_error(loc("Command failed: %1", $captured || ''));
        }

        return $to;

    } else {
        $METHOD_FAIL->{'curl'} = 1;
        return;
    }
}


### use File::Copy for fetching file:// urls ###
### XXX file:// uri to local path conversion is just too weird...
### depend on LWP to do it for us
sub _file_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    ### prefix a / on unix systems with a file uri, since it would
    ### look somewhat like this:
    ###     file://home/kane/file
    ### wheras windows file uris might look like:
    ###     file://C:/home/kane/file
    my $path    = ON_UNIX ? '/'. $self->path : $self->path;

    my $remote  = File::Spec->catfile( $path, $self->file );

    ### File::Copy is littered with 'die' statements :( ###
    my $rv = eval { File::Copy::copy( $remote, $to ) };

    ### something went wrong ###
    if( !$rv or $@ ) {
        return $self->_error(loc("Could not copy '%1' to '%2': %3 %4",
                             $remote, $to, $!, $@));
    }

    return $to;
}

### use /usr/bin/rsync to fetch files
sub _rsync_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = {
        to  => { required => 1, store => \$to }
    };
    check( $tmpl, \%hash ) or return;

    if (my $rsync = can_run('rsync')) {

        my $cmd = [ $rsync ];

        ### XXX: rsync has no I/O timeouts at all, by default
        push(@$cmd, '--timeout=' . $TIMEOUT) if $TIMEOUT;

        push(@$cmd, '--quiet') unless $DEBUG;

        ### DO NOT quote things for IPC::Run, it breaks stuff.
        push @$cmd, $IPC::Cmd::USE_IPC_RUN
                        ? ($self->uri, $to)
                        : (QUOTE. $self->uri .QUOTE, QUOTE. $to .QUOTE);

        my $captured;
        unless(run( command => $cmd,
                    buffer  => \$captured,
                    verbose => $DEBUG )
        ) {

            return $self->_error(loc("Command failed: %1", $captured || ''));
        }

        return $to;

    } else {
        $METHOD_FAIL->{'rsync'} = 1;
        return;
    }
}

#################################
#
# Error code
#
#################################

=pod

=head2 $ff->error([BOOL])

Returns the last encountered error as string.
Pass it a true value to get the C<Carp::longmess()> output instead.

=cut

### error handling the way Archive::Extract does it
sub _error {
    my $self    = shift;
    my $error   = shift;
    
    $self->_error_msg( $error );
    $self->_error_msg_long( Carp::longmess($error) );
    
    if( $WARN ) {
        carp $DEBUG ? $self->_error_msg_long : $self->_error_msg;
    }

    return;
}

sub error {
    my $self = shift;
    return shift() ? $self->_error_msg_long : $self->_error_msg;
}


1;

=pod

=head1 HOW IT WORKS

File::Fetch is able to fetch a variety of uris, by using several
external programs and modules.

Below is a mapping of what utilities will be used in what order
for what schemes, if available:

    file    => LWP, file
    http    => LWP, wget, curl, lynx
    ftp     => LWP, Net::FTP, wget, curl, ncftp, ftp
    rsync   => rsync

If you'd like to disable the use of one or more of these utilities
and/or modules, see the C<$BLACKLIST> variable further down.

If a utility or module isn't available, it will be marked in a cache
(see the C<$METHOD_FAIL> variable further down), so it will not be
tried again. The C<fetch> method will only fail when all options are
exhausted, and it was not able to retrieve the file.

A special note about fetching files from an ftp uri:

By default, all ftp connections are done in passive mode. To change
that, see the C<$FTP_PASSIVE> variable further down.

Furthermore, ftp uris only support anonymous connections, so no
named user/password pair can be passed along.

C</bin/ftp> is blacklisted by default; see the C<$BLACKLIST> variable
further down.

=head1 GLOBAL VARIABLES

The behaviour of File::Fetch can be altered by changing the following
global variables:

=head2 $File::Fetch::FROM_EMAIL

This is the email address that will be sent as your anonymous ftp
password.

Default is C<File-Fetch@example.com>.

=head2 $File::Fetch::USER_AGENT

This is the useragent as C<LWP> will report it.

Default is C<File::Fetch/$VERSION>.

=head2 $File::Fetch::FTP_PASSIVE

This variable controls whether the environment variable C<FTP_PASSIVE>
and any passive switches to commandline tools will be set to true.

Default value is 1.

Note: When $FTP_PASSIVE is true, C<ncftp> will not be used to fetch
files, since passive mode can only be set interactively for this binary

=head2 $File::Fetch::TIMEOUT

When set, controls the network timeout (counted in seconds).

Default value is 0.

=head2 $File::Fetch::WARN

This variable controls whether errors encountered internally by
C<File::Fetch> should be C<carp>'d or not.

Set to false to silence warnings. Inspect the output of the C<error()>
method manually to see what went wrong.

Defaults to C<true>.

=head2 $File::Fetch::DEBUG

This enables debugging output when calling commandline utilities to
fetch files.
This also enables C<Carp::longmess> errors, instead of the regular
C<carp> errors.

Good for tracking down why things don't work with your particular
setup.

Default is 0.

=head2 $File::Fetch::BLACKLIST

This is an array ref holding blacklisted modules/utilities for fetching
files with.

To disallow the use of, for example, C<LWP> and C<Net::FTP>, you could
set $File::Fetch::BLACKLIST to:

    $File::Fetch::BLACKLIST = [qw|lwp netftp|]

The default blacklist is [qw|ftp|], as C</bin/ftp> is rather unreliable.

See the note on C<MAPPING> below.

=head2 $File::Fetch::METHOD_FAIL

This is a hashref registering what modules/utilities were known to fail
for fetching files (mostly because they weren't installed).

You can reset this cache by assigning an empty hashref to it, or
individually remove keys.

See the note on C<MAPPING> below.

=head1 MAPPING


Here's a quick mapping for the utilities/modules, and their names for
the $BLACKLIST, $METHOD_FAIL and other internal functions.

    LWP         => lwp
    Net::FTP    => netftp
    wget        => wget
    lynx        => lynx
    ncftp       => ncftp
    ftp         => ftp
    curl        => curl
    rsync       => rsync

=head1 FREQUENTLY ASKED QUESTIONS

=head2 So how do I use a proxy with File::Fetch?

C<File::Fetch> currently only supports proxies with LWP::UserAgent.
You will need to set your environment variables accordingly. For
example, to use an ftp proxy:

    $ENV{ftp_proxy} = 'foo.com';

Refer to the LWP::UserAgent manpage for more details.

=head2 I used 'lynx' to fetch a file, but its contents is all wrong!

C<lynx> can only fetch remote files by dumping its contents to C<STDOUT>,
which we in turn capture. If that content is a 'custom' error file
(like, say, a C<404 handler>), you will get that contents instead.

Sadly, C<lynx> doesn't support any options to return a different exit
code on non-C<200 OK> status, giving us no way to tell the difference
between a 'successfull' fetch and a custom error page.

Therefor, we recommend to only use C<lynx> as a last resort. This is 
why it is at the back of our list of methods to try as well.

=head2 Files I'm trying to fetch have reserved characters or non-ASCII characters in them. What do I do?

C<File::Fetch> is relatively smart about things. When trying to write 
a file to disk, it removes the C<query parameters> (see the 
C<output_file> method for details) from the file name before creating
it. In most cases this suffices.

If you have any other characters you need to escape, please install 
the C<URI::Escape> module from CPAN, and pre-encode your URI before
passing it to C<File::Fetch>. You can read about the details of URIs 
and URI encoding here:

  http://www.faqs.org/rfcs/rfc2396.html

=head1 TODO

=over 4

=item Implement $PREFER_BIN

To indicate to rather use commandline tools than modules

=back

=head1 BUG REPORTS

Please report bugs or other issues to E<lt>bug-file-fetch@rt.cpan.org<gt>.

=head1 AUTHOR

This module by Jos Boumans E<lt>kane@cpan.orgE<gt>.

=head1 COPYRIGHT

This library is free software; you may redistribute and/or modify it 
under the same terms as Perl itself.


=cut

# Local variables:
# c-indentation-style: bsd
# c-basic-offset: 4
# indent-tabs-mode: nil
# End:
# vim: expandtab shiftwidth=4:



