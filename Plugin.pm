package Plugins::YouTube::Plugin;

# Plugin to stream audio from YouTube videos streams
#
# Released under GPLv2

use strict;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::YouTube::ProtocolHandler;

my $log;
my $compat;

BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.youtube',
		'defaultLevel' => 'WARN',
		'description'  => string('PLUGIN_YOUTUBE'),
	});

	# Always use OneBrowser version of XMLBrowser by using server or packaged version included with plugin
	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

my $prefs = preferences('plugin.youtube');

$prefs->init({ prefer_lowbitrate => 0, recent => [], APIkey => 'AIzaSyBemlW2fYlvmma5HWHPQ22vS1k5LTtCwhQ', APIurl => 'https://www.googleapis.com/youtube/v3' });

tie my %recentlyPlayed, 'Tie::Cache::LRU', 20;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'youtube',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( youtube => (
		after => 'middle',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( youtubevideo => (
		after => 'bottom',
		func  => \&webVideoLink,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( youtube => (
		after => 'middle',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( youtube => (
		after => 'middle',
		name  => 'PLUGIN_YOUTUBE',
		func  => \&searchInfoMenu,
	) );

	if (!$::noweb) {
		require Plugins::YouTube::Settings;
		Plugins::YouTube::Settings->new;
	}

	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}

	Slim::Control::Request::addDispatch(['youtube', 'info'], [1, 1, 1, \&cliInfoQuery]);
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_YOUTUBE' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;

	$recentlyPlayed{ $info->{'url'} } = $info;

	$class->saveRecentlyPlayed;
}

sub saveRecentlyPlayed {
	my $class = shift;
	my $now   = shift;

	unless ($now) {
		Slim::Utils::Timers::killTimers($class, \&saveRecentlyPlayed);
		Slim::Utils::Timers::setTimer($class, time() + 10, \&saveRecentlyPlayed, 'now');
		return;
	}

	my @played;

	for my $key (reverse keys %recentlyPlayed) {
		unshift @played, $recentlyPlayed{ $key };
	}

	$prefs->set('recent', \@played);
}

sub toplevel {
	my ($client, $callback, $args) = @_;

	$callback->([
		{ name => string('PLUGIN_YOUTUBE_TOP'), type => 'link',
		  url  => \&searchHandler, passthrough => [ 'standardfeeds/top_rated_Music', \&_parseVideos ], },

		{ name => string('PLUGIN_YOUTUBE_POP'), type => 'link',
		  url  => \&searchHandler, passthrough => [ 'standardfeeds/most_popular_Music', \&_parseVideos ], },

		#{ name => string('PLUGIN_YOUTUBE_RECENT'), type => 'link',
		#  url  => \&searchHandler,	passthrough => [ 'standardfeeds/most_recent_Music', \&_parseVideos ], },

		{ name => string('PLUGIN_YOUTUBE_FAV'),  type => 'link',
		  url  => \&searchHandler,	passthrough => [ 'standardfeeds/top_favorites_Music', \&_parseVideos ], },

		{ name => string('PLUGIN_YOUTUBE_SEARCH'),  type => 'search',
		  url  => \&searchHandler, passthrough => [ 'videos', \&_parseVideos ] },

		{ name => string('PLUGIN_YOUTUBE_MUSICSEARCH'), type => 'search',
		  url  => \&searchHandler, passthrough => [ 'videos', \&_parseVideos, 'category=music' ] },

		{ name => string('PLUGIN_YOUTUBE_CHANNELSEARCH'), type => 'search',
		  url  => \&searchHandler, passthrough => [ 'channels', \&_parseChannels ] },

		{ name => string('PLUGIN_YOUTUBE_PLAYLISTSEARCH'), type => 'search',
		  url  => \&searchHandler, passthrough => [ 'playlists/snippets', \&_parsePlaylists ] },

		{ name => string('PLUGIN_YOUTUBE_RECENTLYPLAYED'), url  => \&recentHandler, },

		{ name => string('PLUGIN_YOUTUBE_URL'), type => 'search', url  => \&urlHandler, },
	]);
}

sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = 'youtube://' . $args->{'search'};

	# use metadata handler to get track info
	Plugins::YouTube::ProtocolHandler->getMetadataFor(undef, $url, undef, undef,
		sub {
			my $meta = shift;
			if (keys %$meta) {
				$callback->({
					items => [ {
						name => $meta->{'title'},
						url  => $url,
						type => 'audio',
						icon => $meta->{'icon'},
						cover=> $meta->{'cover'},
					} ]
				});
			} else {
				$callback->([ { name => string('PLUGIN_YOUTUBE_BADURL'), type => 'text' } ]);
			}
		}
	) && do {
		$callback->([ { name => string('PLUGIN_YOUTUBE_BADURL'), type => 'text' } ]);
	};
}

sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		unshift  @menu, {
			name => $item->{'name'},
			url  => $item->{'url'},
			icon => $item->{'icon'},
			type => 'audio',
		};
	}

	$callback->({ items => \@menu });
}

sub searchHandler {
	my ($client, $callback, $args, $feed, $parser, $term) = @_;

	# use paging on interfaces which allow otherwise fetch 200 entries for button mode
	my $index    = ($args->{'index'} || 0) + 1;
	my $quantity = $args->{'quantity'} || 200;
	my $search   = $args->{'search'} ? "$args->{search}" : '';
	##$search=~ s/([^a-zA-Z0-9])/sprintf("%%%2X",ord($1))/sge;
	$search=URI::Escape::uri_escape_utf8($search);
	
	$search="q=$search";
	$term ||= '';

	my $menu = [];

	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;

	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??

	$fetch = sub {

		my $i = $index + scalar @$menu;
		my $max = min($quantity - scalar @$menu, 50); # api allows max of 50 items per response

		my $queryUrl;

		if ($feed =~ /^http/) {
			$queryUrl = "$feed&start-index=$i&max-results=$max&v=2&alt=json";
		} else {
		
			##$queryUrl = "http://gdata.youtube.com/feeds/api/$feed?$term&$search&start-index=$i&max-results=$max&v=2&alt=json";
			my $apiurl = $prefs->get('APIurl') . "/search/?";
			if($feed =~ /(rated|favorites|popular)/){
				$apiurl = $prefs->get('APIurl') . "/guideCategories/?";
			}elsif($feed =~ /(channel|playlist)/){
				$apiurl .="type=$1&"; 
			}
			
			$queryUrl="$apiurl";
			if($term){
				$queryUrl.="$term&";
			}
			$queryUrl.="$search&start-index=$i&max-results=$max&v=2&alt=json&part=id,snippet&key=" . $prefs->get('APIkey');
			
			
			
		}

		$log->info("fetching: $queryUrl");
		#$log->debug(" debug fetching: $queryUrl");
		##print STDERR "\nqueryUrl fetching: $queryUrl \n";
		#$log->warn(" warn fetching: $queryUrl");
		###'REMOTE_PORT' => '57643',
        ##  'HTTP_USER_AGENT' => 'iTunes/4.7.1 (Linux; N; Debian; x86_64-linux; EN; utf8) SqueezeCenter, Squeezebox Server, Logitech Media Server/7.9.0/1440053825',

		_debug('queryUrl',$feed,$queryUrl);
		

		Slim::Networking::SimpleAsyncHTTP->new(

			sub {
				my $http = shift;
				
				##$log->warn("result: " . $http->content);
				###return {};
				my $json = eval { from_json($http->content) };
				
				###$log->warn("json::" . $http->content);

				
				if ($@) {
					$log->warn($@);
				}

				my $before = scalar @$menu;

				# parse json response into menu entries
				##$parser->($json->{'feed'}, $menu);
				$parser->($json, $menu);
				##_debug('Parsed json',$json);
				##_debug('Parsed results',$menu);

				# Restrict responses to requested searchmax or 500
				# Youtube API appears to be limited to 1000, but does not always return 1000 results so restrict to 500
				my $total = min($json->{'feed'}->{'openSearch$totalResults'}->{'$t'}, $args->{'searchmax'} || 500, 500);

				$log->debug("this page: " . scalar @$menu . " total: $total");

				if (scalar @$menu < $quantity && $total > $index + scalar @$menu && scalar @$menu > $before) {

					# get some more if we have yet to build the required page for client
					$fetch->();

				} else {

					$callback->({
						items  => $menu,
						offset => $index - 1,
						total  => $total,
					});
				}
			},

			sub {
				###use Data::Dumper;
				###$log->warn("error: $_[1] " . Dumper([@_]));
				$log->warn("error: $_[1] ");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},

		)->get($queryUrl);
	};

	$fetch->();
}

sub _parseVideosV2 {
	my ($json, $menu) = @_;
	for my $entry (@{$json->{'entry'} || []}) {
		my $mg = $entry->{'media$group'};
		push @$menu, {
			name => $mg->{'media$title'}->{'$t'},
			type => 'audio',
			on_select => 'play',
			playall => 0,
			url  => 'youtube://' . $mg->{'yt$videoid'}->{'$t'},
			play => 'youtube://' . $mg->{'yt$videoid'}->{'$t'},
			icon => $mg->{'media$thumbnail'}->[0]->{'url'},
		};
	}
}

sub _parseVideos {
	my ($json, $menu) = @_;
	for my $entry (@{$json->{'items'} || []}) {
		my $mg = $entry->{'snippet'};
		my $vurl = "www.youtube.com/v/$entry->{id}->{videoId}";
		push @$menu, {
			name => $mg->{'title'},
			type => 'audio',
			on_select => 'play',
			playall => 0,
			url  => 'youtube://' . $vurl,
			play => 'youtube://' . $vurl,
			icon => $mg->{'thumbnails'}->{'default'}->{'url'},
		};
	}
	
	
}

sub _debug{
	
	use Data::Dumper;
	
	print STDERR Dumper([caller,@_]);

}
sub _parseChannels {
	my ($json, $menu) = @_;
	###_debug('_parseChannels',$json);
	
	for my $entry (@{$json->{'items'} || []}) {
		my $title = $entry->{'snippet'}->{'title'} || $entry->{'snippet'}->{'description'} || 'No Title';
		$title = Slim::Formats::XML::unescapeAndTrim($title);
		my $id=$entry->{id}->{videoId};
		push @$menu, {
			name => $title,
			type => 'link',
			url  => \&searchHandler,
			passthrough => [ $prefs->{APIurl} . "/channels/?parts=snippet&id=$id&key=" . $prefs->{APIkey}, \&_parseVideos ],
		};
	}
	
	###_debug('_parseChannels results',$menu);
}
sub _parseChannelsV2 {
	my ($json, $menu) = @_;
	###_debug('_parseChannels',$json);
	
	for my $entry (@{$json->{'entry'} || []}) {
		my $title = $entry->{'title'}->{'$t'} || $entry->{'summary'}->{'$t'} || 'No Title';
		$title = Slim::Formats::XML::unescapeAndTrim($title);
		push @$menu, {
			name => $title,
			type => 'link',
			url  => \&searchHandler,
			passthrough => [ $entry->{'gd$feedLink'}->[0]->{'href'}, \&_parseVideos ],
		};
	}
}


sub _parsePlaylists {
	my ($json, $menu) = @_;	
	## for my laziness
	return _parseChannels($json, $menu);
	
	
	for my $entry (@{$json->{'entry'} || []}) {
		my $title = $entry->{'title'}->{'$t'} || $entry->{'summary'}->{'$t'} || 'No Title';
		$title = Slim::Formats::XML::unescapeAndTrim($title);
		push @$menu, {
			name => $title,
			type => 'link',
			url  => \&searchHandler,
			passthrough => [ $entry->{'content'}->{'src'}, \&_parseVideos ],
		};
	}
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($track && $track->artistName);

	$artist = URI::Escape::uri_escape_utf8($artist);

	if ($artist) {
		return {
			type      => 'opml',
			name      => string('PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => sub {
				my ($client, $callback, $args) = @_;
				$args->{'search'} = $artist;
				$args->{'searchmax'} = 200; # only get 200 entries within context menu
				my $cb = !$compat ? $callback : sub { $callback->(shift->{'items'}) };
				searchHandler($client, $cb, $args, 'videos', \&_parseVideos);
			},
			favorites => 0,
		};
	} else {
		return {};
	}
}

sub artistInfoMenu {
	my ($client, $url, $obj, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($obj && $obj->name);

	$artist = URI::Escape::uri_escape_utf8($artist);

	if ($artist) {
		return {
			type      => 'opml',
			name      => string('PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => sub {
				my ($client, $callback, $args) = @_;
				$args->{'search'} = $artist;
				$args->{'searchmax'} = 200; # only get 200 entries within context menu
				my $cb = !$compat ? $callback : sub { $callback->(shift->{'items'}) };
				searchHandler($client, $cb, $args, 'videos', \&_parseVideos);
			},
			favorites => 0,
		};
	} else {
		return {};
	}
}

sub webVideoLink {
	my ($client, $url) = @_;
	_debug('webVideoLink',$url);
	
	if (my $id = Plugins::YouTube::ProtocolHandler->_id($url)) {

		my $show;
		my $i = 0;
		while (my $caller = (caller($i++))[3]) {
			if ($caller =~ /Slim::Web::Pages/) {
				$show = 1;
				last;
			}
			if ($caller =~ /cliQuery/) {
				if ($client->can('controllerUA') && $client->controllerUA =~ /iPeng/) {
					$show = 1;
				}
				last;
			}
		}

		if ($show) {
			return {
				type    => 'text',
				name    => string('PLUGIN_YOUTUBE_WEBLINK'),
				weblink => "http://www.youtube.com/watch?v=$id",
				jive => {
					actions => {
						go => {
							cmd => [ 'youtube', 'info' ],
							params => {
								id => $id,
							},
						},
					},
				},
			};
		}
	}

	return undef;
}

sub searchInfoMenu {
	my ($client, $tags) = @_;

	my $query = $tags->{'search'};

	$query = URI::Escape::uri_escape_utf8($query);

	return {
		name => string('PLUGIN_YOUTUBE'),
		items => [
			{
				name => string('PLUGIN_YOUTUBE_SEARCH'),
				type => 'link',
				url  => sub {
					my ($client, $callback, $args) = @_;
					$args->{'search'} = $query;
					my $cb = !$compat ? $callback : sub { $callback->(shift->{'items'}) };
					searchHandler($client, $cb, $args, 'videos', \&_parseVideos);
				},
				favorites => 0,
			},
			{
				name => string('PLUGIN_YOUTUBE_MUSICSEARCH'),
				type => 'link',
				url  => sub {
					my ($client, $callback, $args) = @_;
					$args->{'search'} = $query;
					my $cb = !$compat ? $callback : sub { $callback->(shift->{'items'}) };
					searchHandler($client, $cb, $args, 'videos', \&_parseVideos, 'category=music');
				},
				favorites => 0,
			},
		   ],
	};
}

# special query to allow weblink to be sent to iPeng
sub cliInfoQuery {
	my $request = shift;

	if ($request->isNotQuery([['youtube'], ['info']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $id = $request->getParam('id');

	$request->addResultLoop('item_loop', 0, 'text', string('PLUGIN_YOUTUBE_PLAYLINK'));
	$request->addResultLoop('item_loop', 0, 'weblink', "http://www.youtube.com/v/$id");
	$request->addResult('count', 1);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

1;
