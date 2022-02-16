package SOAPRequest::Base;

# Description: 
# Generic class for sending xml request via soap.
# Middleware for xml web form submission and soap requests.
# Sub-class this module and just inherit and redefine send_xml().
use strict;

use LWP::UserAgent;
use HTTP::Request;
use Data::Dumper;
use XML::TreePP;

my $treepp  = XML::TreePP->new();
my $package = __PACKAGE__;

# Pass any arguments to the constructor.
sub new {
	my ( $class, %p ) = @_;
	my $self = { map{ $_, $p{ $_ } } keys %p };
	bless ( $self, $class );
	return $self;
}

# Trace profiler which connects to the Trace class.
sub write_trace {
	my ( $self, $args ) = @_;

	my $text       = $args->{text};
	my $trace      = $self->{trace};
	my $trace_type = $args->{trace_type} || 'INFO';

	$trace->WriteTrace( $trace_type, $text ) if $trace;

	return; 
}

# Post xml to the remote web service (soap).
sub send_xml_request {
	my ( $self, $args ) = @_;

	my $req          = $args->{req} || 'POST';
	my $xml          = $args->{xml};
	my $trace        = $args->{trace};
	my $header       = $args->{header};
	my $timeout      = $args->{timeout} || 30;
	my $post_url     = $args->{post_url};
	my $insecure     = $args->{insecure};
	my $no_parse     = $args->{no_parse};
	my $ref_reply    = $args->{ref_reply};
	my $auth_token   = $args->{auth_token};
	my $auth_token2  = $args->{auth_token2};
	my $soap_action  = $args->{soap_action}  || '';
	my $content_type = $args->{content_type} || 'text/xml; charset=utf-8';

	$self->{trace} = $trace if $trace;

	my $response_ref = {};

	if ( $post_url ) {

		# Some SSL certs don't have their DNS setup properly.
		$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0 if $insecure;

		my $ua      = LWP::UserAgent->new();
		my $request = HTTP::Request->new( $req => $post_url );
        
		# Create the soap header to send a soap action, 
		# the double quotes are required.
		$request->header( SOAPAction    => qq~"$soap_action"~ )    if $soap_action;
		$request->header( Authorization => qq~Basic $auth_token~ ) if $auth_token;
		$request->header( Authorization => qq~$auth_token2~ )      if $auth_token2;
		$request->content( $xml ) if $xml;
		$request->content_type( $content_type ) if $content_type ne 'none';

		# Extra headers.
		if ( ref $header eq 'HASH' && %$header ) { 
			my @header_keys = keys %$header;
			
			for my $hkey ( @header_keys ) { 
				my $hval = $header->{ $hkey };
				$request->header( $hkey => $hval ) if length $hval;
			}
		}

		# Record the xml sent in the logs.
		$self->write_trace( { text => "$package send_xml_request request timeout: $timeout" } );
		$self->write_trace( { text => "$package send_xml_request request:  " . Dumper( $request ) } );

		$ua->timeout( $timeout );
		my $response = $ua->request( $request );

		# Better to return $response->{_content} and $response->{_rc} in some cases.
		if ( $ref_reply ) { 

			my $content = $response->{_content};
			my $status  = $response->{_rc};

			if ( $content =~ /timeout/i && $status == 500 ) { 
				$response->{_content} = 'read timeout';
				$self->write_trace( { trace_type => 'ERROR', text => "$package send_xml_request timeout ERROR:  $response->{_content}" } );
			}

			$response_ref = $response;

		} else { 

			my $response_string = $response->as_string;
			my $response_code   = $response->code;
			
			$self->write_trace( { text => $response_string } );
			
			# Here the converting and formatting takes place. 
			if ( $response_string ) {
			
				# Raw response string.
				$response_ref->{raw} = $response_string;
			
				# Expose the XML.
				$response_string = $self->filter_response( { response_string => $response_string } );
			
				# Convert XML into soap format.
				if ( !$no_parse ) { 
					$response_string = $self->convert_soap_xml( { response_string => $response_string } );
				}
			
				$response_ref->{response_string} = $response_string;
				$response_ref->{response_code}   = $response_code;
			}
		}
	}

	$self->write_trace( { text => "$package send_xml_request response:  " . Dumper( $response_ref ) , trace => 'INFO' } );

	return $response_ref;
}

# Filter out text, explose only xml/soap response tags.
sub filter_response {
	my ( $self, $args ) = @_;

	my $response_string = $args->{response_string};	
	$response_string    =~ s/^(.+[^<])+//g;

	return $response_string;
}

# Convert the soap xml into a treepp.
sub convert_soap_xml {
	my ( $self, $args ) = @_;

	my $response_string = $args->{response_string};	
	my $xml_result      = eval { $treepp->parse( $response_string ) };
	
	$self->write_trace( { text => "$package: $@ in $response_string", trace => 'ERROR' } ) if $@;

	return $xml_result;
}

# Validate input hash, or, array of hashes.
# check to see if we have the key defined and there is a value.
# a key is from @tags.
# Returns: error_code. 
# Returns: error_string.
sub validate_params {
	my ( $self, $args ) = @_;

	my $xml_tree = $args->{xml_tree};
	my @tags     = ref $args->{tags} ? @{ $args->{tags} } : ();
	my @data     = ref $args->{data} ? @{ $args->{data} } : ();

	my ( $rc, $error_text ) = ( 0, '' );

	if ( @tags && @data ) { 
		if ( $xml_tree ) {
			my $data_type = ref $data[0];
			if ( $data_type eq 'HASH' ) { 
				for my $d ( @data ) { 
					my @user_tags = keys %$d;
					$error_text .= $self->tag_diff( { valid_tags => \@tags, user_tags => \@user_tags } );
					$error_text .= " " if $error_text;
				}
			} else { 
				$error_text .= $self->tag_diff( { valid_tags => \@tags, user_tags => \@data } );
			}
		} else {
			$self->write_trace( { text => 'Error> no xml_tree input.'  } );
		}
	} else { 
		( $rc, $error_text ) = ( 1, 'Error> no tags array in validate_params().' );
		$self->write_trace( { text => $error_text } );	
	}

	# Sending the error_text back so that the user may see it.
	if ( $error_text ) { 
		$error_text =~ s/\s$// if $error_text =~ /\s$/;
		( $rc, $error_text ) = ( 1, "Missing required parameters: $error_text" );
	}

	return ( $rc, $error_text );
}

# Array diff.  
# input: two arrays
# output: array with diff's.
sub tag_diff {
	my ( $self, $args ) = @_;

	my @valid_tags = ref $args->{valid_tags} ? @{ $args->{valid_tags} } : ();
	my @user_tags  = ref $args->{user_tags}  ? @{ $args->{user_tags} }  : ();

	$self->write_trace( { text => 'Error> tag_diff() missing arrays' } ) unless @valid_tags && @user_tags;

	my %input_tags =  map { $_, 1 } @user_tags;
	my @missing    = ();

	for my $tag ( @valid_tags ) { 
		push @missing, $tag unless $input_tags{ $tag };
	}

	return wantarray() ? @missing : "@missing";
}

1;
