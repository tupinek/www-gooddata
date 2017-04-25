package WWW::GoodData;

=head1 NAME

WWW::GoodData - Client library for GoodData REST-ful API

=head1 SYNOPSIS

  use WWW::GoodData;
  my $gdc = new WWW::GoodData;
  print $gdc->get_uri ('md', { title => 'My Project' });

=head1 DESCRIPTION

B<WWW::GoodData> is the client for GoodData JSON-based API
built atop L<WWW::GoodData::Agent> client agent, with focus
on usefullness and correctness of implementation.

It  provides code for navigating the REST-ful API structure as well as
wrapper funcitons for common actions.

=cut

use strict;
use warnings;

use English;
use WWW::GoodData::Agent;
use JSON;
use URI;

our $root = new URI ('https://secure.gooddata.com/gdc');

=head1 METHODS

=over 4

=item B<new> [PARAMS]

Create a new client instance.

You can optionally pass a hash reference with properties that would be
blessed, otherwise a new one is created. Possible properties include:

=over 8

=item B<agent>

A L<WWW::GoodData::Agent> instance to use.

=item B<retries>

A number of retries to obtain results of asynchronous tasks, such as
report exports or data uploads. See B<poll>.

Defaults to 3600 (delay of one hour).

=back

=cut

sub new
{
	my $class = shift;
	my $self = shift || {};
	bless $self, $class;
	$self->{agent} ||= new WWW::GoodData::Agent ($root);
	$self->{retries} ||= 3600;
	return $self;
}

# API hierarchy traversal Cache
our %links;
sub get_canonical_links
{
	my $self = shift;
	my $root = shift;
	my @path = map { ref $_ ? $_ : { category => $_ } } @_;
	my $link = shift @path;

	unless ($links{$root}) {
		my $response = $self->{agent}->get ($root);
		# Various ways to get the links
		if (exists $response->{about}) {
			# Ordinary structure with about section
			$links{$root} = $response->{about}{links};
		} elsif (exists $response->{query} and exists $response->{query}{entries}) {
			# Inconsistent query entries
			$links{$root} = $response->{query}{entries};
		} elsif (scalar keys %$response == 1) {
			my @elements = ($response);
			my ($structure) = keys %$response;

			# Aggregated resources (/gdc/account/profile/666/projects)
			@elements = @{$response->{$structure}}
				if ref $response->{$structure} eq 'ARRAY';

			$links{$root} = [];
			foreach my $element (@elements) {
				my $root = $root;
				my ($type) = keys %$element;

				# Metadata with interesting information outside "links"
				if (exists $element->{$type}{links}{self}
					and exists $element->{$type}{meta}) {
					my $link = new URI ($element->{$type}{links}{self})->abs ($root);
					push @{$links{$root}}, {
						%{$element->{$type}{meta}},
						category => $type,
						structure => $structure,
						link => $link,
					};
					$root = $link;
				}

				# The links themselves
				foreach my $category (keys %{$element->{$type}{links}}) {
					my $link = new URI ($element->{$type}{links}{$category})->abs ($root);
					push @{$links{$root}}, {
						structure => $structure,
						category => $category,
						type => $type,
						link => $link,
					};
				}
			}

		} else {
			die 'No links';
		}
	}

	# Canonicalize the links
	$_->{link} = new URI ($_->{link})->abs ($root) foreach @{$links{$root}};

	my @matches = grep {
		my $this_link = $_;
		# Filter out those, who lack any of our keys or
		# hold a different value for it.
		not map { not exists $link->{$_}
			or not exists $this_link->{$_}
			or $link->{$_} ne $this_link->{$_}
			? 1 : () } keys %$link
	} @{$links{$root}};

	# Fully resolved
	return @matches unless @path;

	die 'Nonexistent component in path' unless @matches;
	die 'Ambigious path' unless scalar @matches == 1;

	# Traverse further
	return $self->get_canonical_links ($matches[0]->{link}, @path);
}

# This is a 'normalized' version, for convenience and compatibility
sub get_links
{
	my $self = shift;
	my $root = (ref $_[0] and ref $_[0] ne 'HASH') ? shift : '';

	# Canonicalize URIs
	$root = new URI ($root)->abs ($self->{agent}{root});

	# And decanonicalize, ommiting the scheme and authority part if possible
	my @links = $self->get_canonical_links ($root, @_);
	$_->{link} = $_->{link}->rel ($root)->authority
		?  $_->{link} : new URI ($_->{link}->path) foreach @links;

	return @links;
}

=item B<links> PATH

Traverse the links in resource hierarchy following given PATH,
starting from API root (L</gdc> by default).

PATH is an array of dictionaries, where each key-value pair
matches properties of a link. If a plain string is specified,
it is considered to be a match against B<category> property:

  $gdc->links ('md', { 'category' => 'projects' });

The above call returns a list of all projects, with links to
their metadata resources.

=cut

sub links
{
	my @links = get_links @_;
	return @links if @links;
	%links = ();
	return get_links @_;
}

=item B<get_uri> PATH

Follows the same samentics as B<links>() call, but returns an
URI of the first matching resource instead of complete link
structure.

=cut

sub get_uri
{
	[links @_]->[0]{link};
}

=item B<login> EMAIL PASSWORD

Obtain a SST (login token).

=cut

sub login
{
	my $self = shift;
	my ($login, $password, $url_cache) = @_;

	my $root_url = $self->{agent}{root};
	my $root = new URI($root_url);

	my $netloc;
	if ( $url_cache ) {
		die "Provided login '$login' doesn't match cached one '$url_cache->{login}'.\n"
			unless $url_cache->{login} eq $login;
		die "Provided login '$root_url' doesn't match cached one '$url_cache->{root_url}'.\n"
			unless $url_cache->{root_url} eq $root_url;

		$netloc = $url_cache->{netloc};

	} else {
		my $staging = $self->get_uri ('uploads')->abs ($root);
		$netloc = $staging->host.':'.$staging->port;
	}

	$self->{agent}->credentials ($netloc,
		'GoodData project data staging area', $login => $password);

	if ( $url_cache ) {
		$self->{login} = $url_cache->{login_obj};
		$self->{url_cache} = $url_cache;

	} else {
		$self->{login} = $self->{agent}->post ($self->get_uri('login'),
		{postUserLogin => {
			login => $login,
			password => $password,
			remember => 0}});

		$self->{url_cache} = {};
		$self->set_url_cache_kv( 'root_url', $root_url );
		$self->set_url_cache_kv( 'login', $login );
		$self->set_url_cache_kv( 'netloc', $netloc );
		$self->set_url_cache_kv( 'login_obj', $self->{login} );
	}

	return $self->{login};
}

sub set_url_cache_kv {
	my ( $self, $key, $value ) = @_;
	$self->{url_cache}{$key} = $value;
}

sub get_url_cache {
	my $self = shift;
	return $self->{url_cache};
}

=item B<logout>

Make server invalidate the client session and drop
credential tokens.

Is called upon destruction of the GoodData client instance.

=cut

sub logout
{
	my $self = shift;

	die 'Not logged in' unless defined $self->{login};

	# Forget Basic authentication
	my $root = new URI ($self->{agent}{root});
	my $staging = $self->get_uri ('uploads');
	my $netloc = $staging->host.':'.$staging->port;
	$self->{agent}->credentials ($netloc,
		'GoodData project data staging area', undef, undef);

	# The redirect magic does not work for POSTs and we can't really
	# handle 401s until the API provides reason for them...
	$self->{agent}->get ($self->get_uri ('token'));

	$self->{agent}->delete ($self->{login}{userLogin}{state});
	$self->{login} = undef;
}

=item B<change_passwd> OLD NEW

Change user password given the old and new password.

=cut

sub change_passwd
{
	my $self = shift;
	my $old_passwd = shift or die 'No old password given';
	my $new_passwd = shift or die 'No new password given';

	die 'Not logged in' unless defined $self->{login};

	my $profile = $self->{agent}->get ($self->{login}{userLogin}{profile});
	my $new_profile = {
		'accountSetting' => {
			'old_password' => $old_passwd,
			'password' => $new_passwd,
			'verifyPassword' => $new_passwd,
			'firstName' => $profile->{accountSetting}->{firstName},
			'lastName' => $profile->{accountSetting}->{lastName}
		}
	};

	$self->{agent}->put ($self->{login}{userLogin}{profile}, $new_profile);
}

=item B<projects>

Return array of links to project resources on metadata server.

=cut

sub projects
{
	my $self = shift;
	die 'Not logged in' unless $self->{login};

	# Hack to remove cache.
	%links = ();

	$self->get_links (new URI ($self->{login}{userLogin}{profile}),
		qw/projects project/);
}

=item B<delete_project> IDENTIFIER

Delete a project given its identifier.

=cut

sub delete_project
{
	my $self = shift;
	my $project = shift;

	# Instead of directly DELETE-ing the URI gotten, we check
	# the existence of a project with such link, as a sanity check
	my $uri = $self->get_uri (new URI ($project),
		{ category => 'self', type => 'project' }) # Validate it's a project
		or die "No such project: $project";
	$self->{agent}->delete ($uri);
}

=item B<create_project> TITLE SUMMARY TEMPLATE DRIVER TOKEN

Create a project given its title and optionally summary, project template,
db engine driver and authorization token
return its identifier.

The list of valid project templates is available from the template server:
L<https://secure.gooddata.com/projectTemplates/>.

Valid db engine drivers are 'Pg' (default) and 'mysql'.

=cut

sub create_project
{
	my $self = shift;
	my $title = shift or die 'No title given';
	my $summary = shift || '';
	my $template = shift;
	my $driver= shift;
	my $token = shift;
	my $environment = shift;

	# The redirect magic does not work for POSTs and we can't really
	# handle 401s until the API provides reason for them...
	$self->{agent}->get ($self->get_uri ('token'));

	return $self->{agent}->post ($self->get_uri ('projects'), {
		project => {
			content => {
				# No hook to override this; use web UI
				guidedNavigation => 1,
				($driver ? (driver => $driver) : ()),
				($environment ? (environment => $environment) : ()),
				($token ? (authorizationToken => $token) : ())
			},
			meta => {
				summary => $summary,
				title => $title,
				($template ? (projectTemplate => $template) : ()),
			}
	}})->{uri};
}

=item B<create_user> DOMAIN EMAIL LOGIN PASSWORD FIRST_NAME LAST_NAME PHONE COMPANY SSO_PROVIDER

Create a user given its email, login, password, first name, surname, phone and optionally company,
sso provider in domain.

Returns user identifier (URI).

=cut

sub create_user
{
	my $self = shift;
	my $domain_uri = shift || die "No domain specified";
	my $email = shift || die "Email must be specified";
	my $login = shift || $email;
	my $passwd = shift;
	my $firstname = shift;
	my $lastname = shift;
	my $phone = shift;
	my $company = shift || '';
	my $sso_provider = shift;

	return $self->{agent}->post ($domain_uri."/users", { #TODO links does not exists in REST API
		accountSetting => {
			login => $login,
			email => $email,
			password => $passwd,
			verifyPassword => $passwd,
			firstName => $firstname,
			lastName => $lastname,
			phoneNumber => $phone,
			companyName => $company,
			($sso_provider ? (ssoProvider => $sso_provider) : ()),
	}})->{uri};
}

=item B<get_roles> PROJECT

Gets project roles.

Return array of project roles.

=cut

sub get_roles
{
	my $self = shift;
	my $project = shift;

	return $self->{agent}->get (
		$self->get_uri (new URI($project), 'roles'))->{projectRoles}{roles};
}
=item B<reports> PROJECT

Return array of links to repoort resources on metadata server.

=cut

sub reports
{
	my $self = shift;
	my $project = shift;

	die 'Not logged in' unless $self->{login};
	$self->get_links (new URI ($project),
		{ category => 'self', type => 'project' }, # Validate it's a project
		qw/metadata query reports/, {});
}

=item B<compute_report> REPORT

Trigger a report computation and return the URI of the result resource.

=cut

sub compute_report
{
	my $self = shift;
	my $report = shift;

	return $self->{agent}->post (
		$self->get_uri (qw/xtab xtab-executor3/),
		{ report_req => { report => $report }}
	)->{reportResult2}{meta}{uri};
}

=item B<export_report> REPORT FORMAT

Submit an exporter task for a computed report (see B<compute_report>),
wait for completion and return raw data in desired format.

=cut

sub export_report
{
	my $self = shift;
	my $report = shift;
	my $format = shift;

	# Compute the report
	my $result = $self->{agent}->post (
		$self->get_uri (qw/report-exporter exporter-executor/),
		{ result_req => { format => $format,
			report => $self->compute_report ($report) }}
	);

	# This is for new release, where location is finally set correctly;
	$result = $result->{uri} if ref $result eq 'HASH';

	# Trigger the export
	my $exported = $self->poll (
		sub { $self->{agent}->get ($result) },
		sub { $_[0] and exists $_[0]->{raw} and $_[0]->{raw} ne 'null' }
	) or die 'Timed out waiting for report to export';

	# Follow the link
	$exported = $self->{agent}->get ($exported->{uri}) if exists $exported->{uri};

	# Gotten the correctly coded result?
	return $exported->{raw} if $exported->{type} eq {
		png => 'image/png',
		pdf => 'application/pdf',
		xls => 'application/vnd.ms-excel',
	}->{$format};

	die 'Wrong type of content returned';
}

=item B<ldm_picture> PROJECT

Return picture of Logical Data Model (LDM) in PNG format.

=cut

sub ldm_picture
{
	my $self = shift;
	my $project = shift;

	my $model = $self->{agent}->get ($self->{agent}->get (
		$self->get_uri (new URI ($project),
			{ category => 'ldm' }))->{uri});
	die 'Expected PNG image' unless $model->{type} eq 'image/png';

	return $model->{raw};
}

=item B<ldm_manage> PROJECT MAQL

Execute MAQL statement for a project.

=cut

sub ldm_manage
{
	my $self = shift;
	my $project = shift;
	my $maql = shift;

	$maql = "# WWW::GoodData MAQL execution\n$maql";
	chomp $maql;

	$self->{agent}->post (
		$self->get_uri (new URI ($project), qw/metadata ldm ldm-manage/),
		{ manage => { maql => $maql }});
}

=item B<upload> PROJECT MANIFEST

Upload and integrate a new data load via Single Loading Interface (SLI).

=cut

sub upload_upload_data
{
	my $self = shift;
	my $project = shift;
	my $file = shift;
	my $csv_fpath = shift;

	# Parse the manifest
	my $upload_info;
	my $ds_name;
	my $data_fname;
	if ( $file ) {
		$upload_info = decode_json (slurp_file ($file));
		die "$file: not a SLI manifest"
			unless $upload_info->{dataSetSLIManifest};

		$csv_fpath = $upload_info->{dataSetSLIManifest}{file} unless $csv_fpath;
		$ds_name = $upload_info->{dataSetSLIManifest}{dataSet};
		$data_fname = $upload_info->{dataSetSLIManifest}{file};
	} else {
		$ds_name = 'upload-zip';
		$data_fname = 'upload.zip';
	}

	# Construct unique URI in staging area to upload to
	my $uploads = new URI ($self->get_uri ('uploads'));
	$uploads->path_segments (
		$uploads->path_segments,
		$ds_name.'-'.time.'-'.$$.'-'.(int rand 10000)
	);
	$self->{agent}->request (new HTTP::Request (MKCOL => $uploads));

	# Upload the manifest
	if ( $file ) {
		my $manifest = $uploads->clone;
		$manifest->path_segments ($manifest->path_segments, 'upload_info.json');
		$self->{agent}->request (new HTTP::Request (PUT => $manifest,
			['Content-Type' => 'application/json'], encode_json ($upload_info)));
	}

	# Upload CSV
	my $csv = $uploads->clone;
	$csv->path_segments ($csv->path_segments, $data_fname);
	$self->{agent}->request (new HTTP::Request (PUT => $csv,
		['Content-Type' => 'application/csv'],
		(slurp_file ($csv_fpath)
			|| die 'No CSV file specified in SLI manifest')));

	return {
		project => $project,
		uploads => $uploads,
	};
}

sub upload_post_task
{
	my $self = shift;
	my $upload_info = shift;

	my $project = $upload_info->{project};
	my $uploads = $upload_info->{uploads};

	# Trigger the integration
	my $task = $self->{agent}->post (
		$self->get_uri (new URI ($project),
			{ category => 'self', type => 'project' }, # Validate it's a project
			qw/metadata etl pull2/),
		{ pullIntegration => [$uploads->path_segments]->[-1] }
	)->{pull2Task}{links}{poll};

	return $task;
}

sub upload_poll
{
	my $self = shift;
	my $task = shift;

	# Wait for the task to enter a stable state
	my $result = $self->poll (
		sub { $self->{agent}->get ($task) },
		sub { shift->{wTaskStatus}{status} !~ /^(RUNNING)$/ }
	) or die 'Timed out waiting for integration to finish';

	return if $result->{wTaskStatus}{status} eq 'OK';

	die
		'Upload finished with '.$result->{wTaskStatus}{status}." status and message:\n"
		. $result->{wTaskStatus}{messages}[0]{error}{message} . "\nand parameters:\n"
		. join("; ", @{ $result->{wTaskStatus}{messages}[0]{error}{parameters} } ) ."\n"
	;
}


sub upload
{
	my $self = shift;
	my ( @all_params ) = @_;

	my $upload_info = $self->upload_upload_data( @all_params );
	my $task_uri = $self->upload_post_task( $upload_info );
	return $self->upload_poll( $task_uri );
}

=item B<poll> BODY CONDITION

Should only be used internally.

Run BODY passing its return value to call to CONDITION until it
evaluates to true or B<retries> (see properties) times out.

Returns value is of last iteration of BODY in case
CONDITION succeeds, otherwise undefined (in case of timeout).

=cut

sub poll
{
        my $self = shift;
        my ($body, $cond) = @_;
        my $retries = $self->{retries};

        while ($retries--) {
                my $ret = $body->();
                return $ret if $cond->($ret);
                sleep 1;
        }

        return undef;
}

=item B<create_object_with_expression> PROJECT URI TYPE TITLE SUMMARY EXPRESSION

Create a new metadata object of type TYPE with EXPRESSION as the only content.

=cut

sub create_object_with_expression
{
	my $self = shift;
	my $project = shift;
	my $uri = shift;
	my $type = shift or die 'No type given';
	my $title = shift or die 'No title given';
	my $summary = shift || '';
	my $expression = shift or die 'No expression given';

	if (defined $uri) {
		$uri = new URI ($uri);
	} else {
		$uri = $self->get_uri (new URI ($project), qw/metadata obj/);
	}

	return $self->{agent}->post (
		$uri,
		{ $type => {
			content => {
				expression => $expression
			},
			meta => {
				summary => $summary,
				title => $title,
			}
		}}
	)->{uri};
}

=item B<create_report_definition> PROJECT URI TITLE SUMMARY METRICS DIM FILTERS

Create a new reportDefinition in metadata.

=cut

sub create_report_definition
{
	my $self = shift;
	my $project = shift;
	my $uri = shift;
	my $title = shift or die 'No title given';
	my $summary = shift || '';
	my $metrics = shift || [];
	my $dim = shift || [];
	my $filters = shift || [];

	if (defined $uri) {
		$uri = new URI ($uri);
	} else {
		$uri = $self->get_uri (new URI ($project), qw/metadata obj/);
	}

	return $self->{agent}->post (
		$uri,
		{ reportDefinition => {
			content => {
				filters => [ map +{ expression => $_ }, @$filters ],
				grid => {
					columns => [ "metricGroup" ],
					metrics => [ map +{ alias => '', uri => $_ }, @$metrics ],
					rows => [ map +{ attribute => { alias => '', uri => $_,
						totals => [[]] } }, @$dim ],
					sort => {
						columns => [],
						rows => [],
					},
					columnWidths => []
				},
				format => "grid"
			},
			meta => {
				summary => $summary,
				title => $title,
			}
		}}
	)->{uri};
}

=item B<dd_pull> PROJECT ZIP_FILE DATASETS

Integrate a custom date dimension load via Single Loading Interface (SLI).

=cut

sub dd_pull {
	my ($self, $project, $zip_file, $datasets) = @_;

	# Trigger the integration
	my $task_url = $self->{agent}->post(
		$self->get_uri(
			URI->new($project),

			# Validate it's a project
			{
				category => 'self',
				type => 'project',
			},
			qw/metadata datedimension pull/
		), {
			dateIntegration => {
				file => $zip_file,
				datasets => $datasets,
			},
		},
	)->{asyncTask}{link}{poll};

	return $self->upload_poll($task_url);
}

=item B<uploads> FILE_PATH FILE UPLOAD_PATH

Uploads to WebDAV service.

=cut

sub uploads {
	my ($self, $file_path, $upload_path) = @_;
	if (! -r $file_path) {
		die "Cannot read '$file_path' file for upload.";
	}
	my $uploads = URI->new($self->get_uri('uploads'));
	my @collections = split m/\//ms, $upload_path;
	my $file = pop @collections;
	foreach my $collection (@collections) {
		$uploads->path_segments($uploads->path_segments, $collection);
		if (! $self->_collection_exists($uploads)) {
			$self->{agent}->request(HTTP::Request->new(MKCOL => $uploads));
		}
	}
	$uploads->path_segments($uploads->path_segments, $file);
	$self->{agent}->request(HTTP::Request->new(
		PUT => $uploads,
		undef,
		slurp_file($file_path),
	));
	return $uploads;
}

sub _collection_exists {
	my ($self, $uploads) = @_;
	my $wd_check_col_xml = <<'END';
<?xml version="1.0"?>
<propfind xmlns="DAV:">
   <prop>
      <resourcetype />
   </prop>
</propfind>
END

	# XXX Hack because WWW::GoodData::Agent changes LWP::UserAgent behavior.
	eval {
		$self->{agent}->request(HTTP::Request->new(
			PROPFIND => $uploads,
			undef,
			$wd_check_col_xml,
		));
	};
	if ($EVAL_ERROR =~ '^404') {
		return 0;
	} else {
		return 1;
	}
}

=item B<DESTROY>

Log out the session with B<logout> unless not logged in.

=cut

sub DESTROY
{
	my $self = shift;
	#$self->logout if $self->{login};
}

sub slurp_file
{
        my $file = shift;
        open (my $fh, '<', $file) or die "$file: $!";
        return join '', <$fh>;
}

=back

=head1 SEE ALSO

=over

=item *

L<http://developer.gooddata.com/api/> -- API documentation

=item *

L<https://secure.gooddata.com/gdc/> -- Browsable GoodData API

=item *

L<WWW::GoodData::Agent> -- GoodData API-aware user agent

=back

=head1 COPYRIGHT

Copyright 2011, 2012, 2013 Lubomir Rintel

Copyright 2012, 2013 Adam Stulpa, Jan Orel, Tomas Janousek

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHORS

Lubomir Rintel C<lkundrak@v3.sk>

Adam Stulpa C<adam.stulpa@gooddata.com>

Jan Orel C<jan.orel@gooddata.com>

Tomas Janousek C<tomi@nomi.cz>

=cut

1;
