#!/usr/local/bin/perl

# $Header: /mhub4/sources/imap-tools/delIMAPdups.pl,v 1.16 2012/03/10 05:24:10 rick Exp $

#######################################################################
#   Description                                                       #
#                                                                     #
#   delIMAPdups looks for duplicate messages in an IMAP account,      #
#   looking for messages in each mailbox that have the same Message   #
#   ID.  When a duplicate message is found the DELETED flag is set.   #
#   If the -p argument has been supplied then an EXPUNGE operation    #
#   is executed against the mailbox in which the message resides,     #
#   causing the messages which are marked for DELETE to be removed.   #
#                                                                     #
#   Note that delIMAPdups does not check for duplicate copies of      #
#   messages across multiple mailboxes since it is often useful to    #
#   cross-file messages in multiple mailboxes.                        #
#                                                                     #
#   Usage:    ./deldups -S host/user/password                         # 
#                       [-m mailbox list (comma-delimited)]           #
#                       [-L logfile]                                  #
#                       [-p]   purge messages                         #
#                       [-d]   debug mode                             #
#   See usage() for additional arguments.                             #
#######################################################################

############################################################################
# Copyright (c) 2008 Rick Sanders <rfs9999@earthlink.net>                  #
#                                                                          #
# Permission to use, copy, modify, and distribute this software for any    #
# purpose with or without fee is hereby granted, provided that the above   #
# copyright notice and this permission notice appear in all copies.        #
#                                                                          #
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES #
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF         #
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR  #
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES   #
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN    #
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF  #
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.           #
############################################################################

# use Socket;
use FileHandle;
use Fcntl;
use Getopt::Std;
use IO::Socket;

#################################################################
#            Main program.                                      #
#################################################################

   init();
   sigprc();

   #  Get list of all messages on the host by Message-ID
   #
   connectToHost($host, \$conn);
   login($user,$pwd, $conn);
   @mbxs = getMailboxList($user, $conn);

   if ( $md5_hash ) {
      Log("Looking for duplicate messages using an MD5-digest hash of the body");
   } else {
      Log("Looking for duplicate messages using the $keyfield");
   }

   foreach $mbx ( @mbxs ) {
        Log("   Checking mailbox $mbx");
        %msgList = ();
        @msgs = ();
	getMsgList( $keyfield, $mbx, \@msgs, $conn ); 
        selectMbx( $mbx, $conn);
        foreach $msg ( @msgs ) {
             # ($msgnum,$msgid,$subject,$date) = split(/\|/, $msg); 
             ($msgnum,$key,$date) = split(/\|\|\|/, $msg);

             if ( $md5_hash ) {
                Log("Using md5 hash of msg body as the key") if $debug;
                fetch_msg_body( $msgnum, $conn, \$message );
                $key = hash( \$message );
                Log("msgnum:$msgnum hash $key") if $debug;
             } else {
                if ( $use_date ) {
                   Log("Using $keyfield + date as the key") if $debug;
                   $key = "$key $date";
                   Log("key $key") if $debug;
                 } else {
                   Log("Using $keyfield") if $debug;
                 }
             }

             Log("key $key") if $debug;
             if ( $msgList{"$key"} eq '' ) {
                $msgList{"$key"} = $msgnum;
             } else {
                #  Duplicate message
                Log("       Msgnum $msgnum is a duplicate of msgnum $msgList{\"$msgid\"}") if $debug;
                if ( !$purge and !$move2mbx ) {
                   Log("Would have purged msgnum $msgnum");
                   next;
                }
                if ( $move2mbx ) {
                   $moved++ if moveMsg( $mbx, $msgnum, $move2mbx, $conn );
                }
                deleteMsg( $mbx, $msgnum, $conn );
                $expungeMbxs{"$mbx"} = 1;
             }
        }
   }

   if ( $purge or $move2mbx ) {
      @mbxs = keys %expungeMbxs;
      foreach $mbx ( @mbxs ) {
          expungeMbx( $mbx, $conn );
      }
   }

   logout( $conn );

   if ( $move2mbx ) {
      Log("Total messages moved  $moved");
   } else {
      Log("Total messages purged $total");
   }
   exit;


sub init {

   $version = 'V1.2';
   $os = $ENV{'OS'};

   processArgs();

   $timeout = 60 unless $timeout;

   #  Determine whether we have SSL support via openSSL and IO::Socket::SSL
   $ssl_installed = 1;
   eval 'use IO::Socket::SSL';
   if ( $@ ) {
      $ssl_installed = 0;
   }

   if ( $md5_hash ) {
      use Digest::MD5 qw(md5_hex);
   }

   #  Open the logFile
   #
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
      } 
      select(LOG); $| = 1;
   }
   Log("\n$0 starting");
   $total=$moved=0;

}

#
#  sendCommand
#
#  This subroutine formats and sends an IMAP protocol command to an
#  IMAP server on a specified connection.
#

sub sendCommand
{
    local($fd) = shift @_;
    local($cmd) = shift @_;

    print $fd "$cmd\r\n";

    if ($showIMAP) { Log (">> $cmd",2); }
}

#
#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse
{
    local($fd) = shift @_;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    if ($showIMAP) { Log ("<< $response",2); }
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDERR.
#

sub Log {
 
my $str = shift;

   #  If a logile has been specified then write the output to it
   #  Otherwise write it to STDOUT

   if ( $logfile ) {
      ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
      if ($year < 99) { $yr = 2000; }
      else { $yr = 1900; }
      $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s %s\n",
		     $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$$,$str);
      print LOG "$line";
   } 
   print STDOUT "$str\n";

}


#  Make a connection to an IMAP host

sub connectToHost {

my $host = shift;
my $conn = shift;

   Log("Connecting to $host") if $debug;
   
   ($host,$port) = split(/:/, $host);
   $port = 143 unless $port;

   # We know whether to use SSL for ports 143 and 993.  For any
   # other ones we'll have to figure it out.
   $mode = sslmode( $host, $port );

   if ( $mode eq 'SSL' ) {
      unless( $ssl_installed == 1 ) {
         warn("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         Log("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         exit;
      }
      Log("Attempting an SSL connection") if $debug;
      $$conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        $error = IO::Socket::SSL::errstr();
        Log("Error connecting to $host: $error");
        exit;
      }
   } else {
      #  Non-SSL connection
      Log("Attempting a non-SSL connection") if $debug;
      $$conn = IO::Socket::INET->new(
         Proto           => "tcp",
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        Log("Error connecting to $host:$port: $@");
        warn "Error connecting to $host:$port: $@";
        exit;
      }
   } 
   Log("Connected to $host on port $port");

}

sub sslmode {

my $host = shift;
my $port = shift;
my $mode;

   #  Determine whether to make an SSL connection
   #  to the host.  Return 'SSL' if so.

   if ( $port == 143 ) {
      #  Standard non-SSL port
      return '';
   } elsif ( $port == 993 ) {
      #  Standard SSL port
      return 'SSL';
   }
      
   unless ( $ssl_installed ) {
      #  We don't have SSL installed on this machine
      return '';
   }

   #  For any other port we need to determine whether it supports SSL

   my $conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
    );

    if ( $conn ) {
       close( $conn );
       $mode = 'SSL';
    } else {
       $mode = '';
    }

   return $mode;
}

#  trim
#
#  remove leading and trailing spaces from a string
sub trim {
 
local (*string) = @_;

   $string =~ s/^\s+//;
   $string =~ s/\s+$//;

   return;
}


#  login
#
#  login in at the host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $conn = shift;

   $rsn = 1;
   sendCommand ($conn, "$rsn LOGIN $user $pwd");
   while (1) {
	readResponse ( $conn );
	if ($response =~ /^$rsn OK/i) {
		last;
	}
	elsif ($response =~ /NO/) {
		Log ("unexpected LOGIN response: $response");
		return 0;
	}
   }
   Log("Logged in as $user") if $debug;

   return 1;
}


#  logout
#
#  log out from the host
#
sub logout {

my $conn = shift;

   ++$lsn;
   undef @response;
   sendCommand ($conn, "$lsn LOGOUT");
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^$lsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected LOGOUT response: $response");
		last;
	}
   }
   close $conn;
   return;
}


#  getMailboxList
#
#  get a list of the user's mailboxes from the host
#
sub getMailboxList {

my $user = shift;
my $conn = shift;
my @mbxs;

   #  Get a list of the user's mailboxes
   #
  if ( $mbxList ) {
      #  The user has supplied a list of mailboxes so only processes
      #  the ones in that list
      @mbxs = split(/,/, $mbxList);
      # for $i (0..$#mbxs ) { 
      #	$mbxs[$i] =~ s/^\s+//; 
      #	$mbxs[$i] =~ s/\s+$//; 
      # }
      return @mbxs;
   }

   if ($debugMode) { Log("Get list of user's mailboxes",2); }

   sendCommand ($conn, "$rsn LIST \"\" *");
   undef @response;
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^$rsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		return 0;
	}
   }

   undef @mbxs;
   for $i (0 .. $#response) {
	# print STDERR "$response[$i]\n";
	$response[$i] =~ s/\s+/ /;
	($dmy,$mbx) = split(/"\/" /,$response[$i]);
	# $mbx =~ s/^\s+//;  $mbx =~ s/\s+$//;
	$mbx =~ s/"//g;

	if ($response[$i] =~ /NOSELECT/i) {
		if ($debugMode) { Log("$mbx is set NOSELECT,skip it",2); }
		next;
	}
	if (($mbx =~ /^\#/) && ($user ne 'anonymous')) {
		#  Skip public mbxs unless we are migrating them
		next;
	}
	if ($mbx =~ /^\./) {
		# Skip mailboxes starting with a dot
		next;
	}
	push ( @mbxs, $mbx ) if $mbx ne '';
   }

   return @mbxs;
}

#  getMsgList
#
#  Get a list of the user's messages in the indicated mailbox on
#  the host
#
sub getMsgList {

my $field   = shift;
my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $seen;
my $empty;
my $msgnum;

   trim( *mailbox );
   sendCommand ($conn, "1 EXAMINE \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ /^1 OK/i ) {
		# print STDERR "response $response\n";
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		# print STDERR "Error: $response\n";
		return 0;
	}
        elsif ( $response =~ /^* 0 EXISTS/i ) {
                $empty = 1;
        }
   }

   return if $empty;

   sendCommand ( $conn, "1 FETCH 1:* (uid flags internaldate body[header.fields ($field)])");
   undef @response;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ /^1 OK/i ) {
		# print STDERR "response $response\n";
		last;
	}
        elsif ( $response =~ /Broken pipe|Connection reset by peer/i ) {
              print STDOUT "Fetch from $mailbox: $response\n";
              exit;
        }
        elsif ( $response =~ /^1 BAD|^1 NO/i ) {
              Log("Unexpected response $response");
              return 0;
        }
   }

   #  Get a list of the msgs in the mailbox
   #
   undef @msgs;
   undef $flags;
   for $i (0 .. $#response) {
	$seen=0;
	$_ = $response[$i];

	last if /OK FETCH complete/;

	if ( $response[$i] =~ /FETCH \(UID / ) {
	   $response[$i] =~ /\* ([^FETCH \(UID]*)/;
	   $msgnum = $1;
	}

	if ($response[$i] =~ /FLAGS/) {
	    #  Get the list of flags
	    $response[$i] =~ /FLAGS \(([^\)]*)/;
   	    $flags =~ s/\\Recent//;
	    $flags = $1;
	}
        if ( $response[$i] =~ /INTERNALDATE ([^\)]*)/ ) {
            $response[$i] =~ /INTERNALDATE (.+) BODY/i;
            $date = $1;
            $date =~ s/"//g;
	}
        if ( $response[$i] =~ /^Subject:/ ) {
	   $response[$i] =~ /Subject: (.+)/;
           $subject = $1;
        }
	if ( $response[$i] =~ /^$field:/i ) {
	    ($label,$value) = split(/:\s*/, $response[$i],2);
            trim(*value);
            if ( $value eq '' ) {
               # Line-wrap, get it from the next line
               $value = $response[$i+1];
               trim(*value);
            }
            if ( $debug ) {
               Log("$msgnum   $value   $date $subject");
            }
            $value = lc( $value );
	    push (@$msgs,"$msgnum|||$value|||$date");
        }

   }
}


sub fetch_msg_body {

my $msgnum = shift;
my $conn   = shift;
my $message = shift;

   #  Fetch the body of the message less the headers

   Log("   Fetching msg $msgnum...") if $debug;

   sendCommand( $conn, "$rsn FETCH $msgnum (rfc822)");
   while (1) {
	readResponse ($conn);
	if ( $response =~ /^$rsn OK/i ) {
		$size = length($message);
		last;
	} 
	elsif ($response =~ /message number out of range/i) {
		Log ("Error fetching uid $uid: out of range",2);
		$stat=0;
		last;
	}
	elsif ($response =~ /Bogus sequence in FETCH/i) {
		Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
		$stat=0;
		last;
	}
	elsif ( $response =~ /message could not be processed/i ) {
		Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		$stat=0;
		last;
	}
	elsif 
	   ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
		($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
		$cc = 0;
		$$message = "";
		while ( $cc < $len ) {
			$n = 0;
			$n = read ($conn, $segment, $len - $cc);
			if ( $n == 0 ) {
				Log ("unable to read $len bytes");
				return 0;
			}
			$$message .= $segment;
			$cc += $n;
		}
	}
   }

}


sub usage {

   print STDOUT "usage:\n";
   print STDOUT " deldups -S host/user/password\n";
   print STDOUT " Optional arguments:\n";
   print STDOUT "          -p purge duplicate messages\n";
   print STDOUT "          -M <mailbox to put duplicates into>\n";
   print STDOUT "          -d debug\n";
   print STDOUT "          -L logfile\n";
   print STDOUT "          -m mailbox list (eg \"Inbox, Drafts, Notes\". Default is all mailboxes)\n";
   print STDOUT "          -u include the date in the key field to determine uniqueness\n";
   print STDOUT "          -H use an MD5 hash of the message body to determine uniqueness\n";
   print STDOUT "          -F <field> Use <field> to determine duplicate messages\n";
   exit;

}

sub processArgs {

   if ( !getopts( "dS:L:Im:hpuM:HF:" ) ) {
      usage();
   }

   ($host,$user,$pwd) = split(/\//, $opt_S);
   $mbxList  = $opt_m;
   $logfile  = $opt_L;
   $move2mbx = $opt_M;
   $purge    = 1 if $opt_p;
   $debug    = 1 if $opt_d;
   $showIMAP = 1 if $opt_I;
   $use_date = 1 if $opt_u;
   $md5_hash = 1 if $opt_H;
   $keyfield = $opt_F;

   $keyfield = 'Message-ID' if !$keyfield;

   usage() if $opt_h;

}

sub findMsg {

my $conn  = shift;
my $msgid = shift;
my $mbx   = shift;
my $msgnum;

   Log("SELECT $mbx") if $debug;
   sendCommand ( $conn, "1 SELECT \"$mbx\"");
   while (1) {
	readResponse ($conn);
	last if $response =~ /^1 OK/;
   }

   Log("Search for $msgid") if $debug;
   sendCommand ( $conn, "$rsn SEARCH header Message-ID \"$msgid\"");
   while (1) {
	readResponse ($conn);
	if ( $response =~ /\* SEARCH /i ) {
	   ($dmy, $msgnum) = split(/\* SEARCH /i, $response);
	   ($msgnum) = split(/ /, $msgnum);
	}

	last if $response =~ /^1 OK/;
	last if $response =~ /complete/i;
   }

   return $msgnum;
}

sub deleteMsg {

my $mbx    = shift;
my $msgnum = shift;
my $conn   = shift;
my $rc;

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
	   $rc = 1;
	   Log("       Marked msg number $msgnum for delete");
	   last;
	}

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   Log("Error setting \Deleted flag for msg $msgnum: $response");
	   $rc = 0;
	   last;
	}
   }

   return $rc;

}

sub expungeMbx {

my $mbx   = shift;
my $conn  = shift;

   print STDOUT "Purging mailbox $mbx...";

   sendCommand ($conn, "$rsn SELECT \"$mbx\"");
   while (1) {
        readResponse ($conn);
        last if ( $response =~ /^$rsn OK/i );
   }

   sendCommand ( $conn, "1 EXPUNGE");
   $expunged=0;
   while (1) {
        readResponse ($conn);
        $expunged++ if $response =~ /\* (.+) Expunge/i;
        last if $response =~ /^1 OK/;

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   print "Error purging messages: $response\n";
	   last;
	}
   }

   $total += $expunged;

   print STDOUT "$expunged messages purged\n";

}

sub updateFlags {

my $conn  = shift;
my $msgid = shift;
my $mbx   = shift;
my $flags = shift;
my $rc;

   if ( $debug ) {
      Log("Find $msgid");
      Log("flags $flags");
   }

   $msgnum = findMsg( $conn, $msgid, $mbx );
   Log("msgnum is $msgnum") if $debug;

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS ($flags)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
	   Log("   Updated flags for $msgid");
	   $rc = 1;
	   last;
	}

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Error setting flags for $msgid: $response");
	   $rc = 0;
           last;
        }
   }
   return $rc;
}

sub dieright {
   local($sig) = @_;
   print STDOUT "caught signal $sig\n";
   logout( $conn );
   exit(-1);
}

sub sigprc {

   $SIG{'HUP'} = 'dieright';
   $SIG{'INT'} = 'dieright';
   $SIG{'QUIT'} = 'dieright';
   $SIG{'ILL'} = 'dieright';
   $SIG{'TRAP'} = 'dieright';
   $SIG{'IOT'} = 'dieright';
   $SIG{'EMT'} = 'dieright';
   $SIG{'FPE'} = 'dieright';
   $SIG{'BUS'} = 'dieright';
   $SIG{'SEGV'} = 'dieright';
   $SIG{'SYS'} = 'dieright';
   $SIG{'PIPE'} = 'dieright';
   $SIG{'ALRM'} = 'dieright';
   $SIG{'TERM'} = 'dieright';
   $SIG{'URG'} = 'dieright';
}

sub moveMsg {

my $mbx    = shift;
my $msgnum = shift;
my $dstmbx = shift;
my $conn   = shift;
my $moved=0;

   #  Move a message from one mailbox to another.

   return 0 unless $msgnum;

   Log("       Moving msgnum $msgnum to $dstmbx");

   #  Create the mailbox if it doesn't already exist
   sendCommand ($conn, "1 CREATE \"$dstmbx\"");
   while ( 1 ) {
       readResponse ($conn);
       last if $response =~ /^1 OK/i;
       if ( $response !~ /^\*/ ) {
          if (!($response =~ /already exists|file exists|can\'t create/i)) {
              ## print STDOUT "WARNING: $response\n";
          }
          last;
       }
   }

   sendCommand ($conn, "1 COPY $msgnum \"$dstmbx\"");
   while (1) {
        readResponse ( $conn );
        if ( $response =~ /^1 OK/i ) {
           $moved=1;
           last; 
        }
        if ($response =~ /^1 NO|^1 BAD/) {
           Log("unexpected COPY response: $response");
           Log("Please verify that mailbox $dstmbx exists");
           exit;
        }
   }

   return $moved;
}

sub hash {

my $msg = shift;
my $body;
my $boundary;

   #  Generate an MD5 hash of the message body

   #  Strip the header and the MIME boundary markers
   my $header = 1;
   foreach $_ ( split(/\n/, $$msg ) ) {
      if ( $header ) {
         if (/boundary="(.+)"/i ) {
            $boundary = $1;
         }
         $header = 0 if length( $_ ) == 1;
      }
       
      next if /$boundary/;
      $body .= "$_\n" unless $header;
   }

   my $md5 = md5_hex($body);
   Log("md5 hash $md5") if $debug;

   return $md5;
}

sub fetchMsg {

my $msgnum = shift;
my $conn   = shift;
my $message = shift;

   Log("   Fetching msg $msgnum...") if $debug;

   sendCommand( $conn, "1 FETCH $msgnum body[text]");
   while (1) {
	readResponse ($conn);
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;
	if ( $response =~ /^1 OK/i ) {
		$size = length($message);
		last;
	} 
	elsif ($response =~ /message number out of range/i) {
		Log ("Error fetching uid $uid: out of range",2);
		$stat=0;
		last;
	}
	elsif ($response =~ /Bogus sequence in FETCH/i) {
		Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
		$stat=0;
		last;
	}
	elsif ( $response =~ /message could not be processed/i ) {
		Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		$stat=0;
		last;
	}
	elsif 
	   ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
		($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
		$cc = 0;
		$$message = "";
		while ( $cc < $len ) {
			$n = 0;
			$n = read ($conn, $segment, $len - $cc);
			if ( $n == 0 ) {
				Log ("unable to read $len bytes");
				return 0;
			}
			$$message .= $segment;
print STDERR "XXX $$message\n";
			$cc += $n;
		}
	}
   }

}

sub selectMbx {

my $mbx = shift;
my $conn = shift;

   #  Select the mailbox

   sendCommand( $conn, "1 SELECT \"$mbx\"");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD|^\* BYE/i ) {
         Log("Unexpected response to SELECT $mbx command: $response");
         last;
      }
   }

}

