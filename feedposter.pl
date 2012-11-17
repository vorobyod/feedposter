#!/usr/bin/perl -w
# 
# feedposter.pl - a script that does 2 things:
#     1) process RSS feed and get all articles that have specified keywords;
#     2) get HTML-only version of an article
#     3) post to Wordpress blog
#

use strict;

use DateTime::Format::ISO8601;
use DateTime::Format::RSS;
use Data::Dumper;
use DBI;
use LWP::UserAgent;
use WordPress::XMLRPC;
use XML::Simple;
use YAML qw( LoadFile );

use constant CONFIG_FILE => 'feedposter.yaml';
use constant DEBUG => 1;
use constant FEEDS_DB_FILE => 'feeds_data.db';

my $config = LoadFile(CONFIG_FILE);
my $blog_config = $config->{blog};

# Say hi
print "\nFeedPoster - v1.0\n\n";

# Create Wordpress proxy object
my $wp = WordPress::XMLRPC->new({
    username => $blog_config->{blog_username},
    password => $blog_config->{blog_password},
    proxy => $blog_config->{post_url}
});

# Set connection args
$wp->server()->transport()->proxy()->ssl_opts( verify_hostname => 0 );

# Set fields for basic auth
if ($blog_config->{http_auth}) {
    my $auth_config = $blog_config->{http_auth_credentials};
    $wp->server()->transport()->proxy()->credentials(
        $auth_config->{netloc},
        $auth_config->{realm},
        $auth_config->{username},
        $auth_config->{password}
    );
}

# Get categories and tags from blog
print "Getting categories and tags from blog . . .";
print "done\n";

my @categories = ();
foreach my $category_rec (@{$wp->getCategories()}) {
    push @categories, $category_rec->{categoryName};
}
@categories = sort @categories;
print Dumper({categories => \@categories}) if (DEBUG);

my @tags = ();
foreach my $tag_rec (@{$wp->getTags()}) {
    push @tags, $tag_rec->{name};
}
@tags = sort @tags;
print Dumper({tags => \@tags}) if (DEBUG);

printf("We got %d categories, %d tags\n", scalar(@categories), scalar(@tags));

# Process feeds
my @feeds = @{$config->{feeds}};

unless (scalar(@feeds)) {
    print "\nNo feeds to process!\nPlease edit config file feedposter.yaml\n\n";
    exit(0);
}

print "Processing feeds, " . scalar(@feeds) . " to process\n";

foreach my $feed (@feeds) {
    print "Processing feed $feed->{name} . . .\n";
    
    # Get RSS feed items
    my $feed_data = get_feed_data(feed => $feed);

    # Get last update date/time for a feed and get all articles
    # newer than that date
    my $new_feed_items = get_new_feed_items(
        feed => $feed,
        feed_data => $feed_data
    );
    if (scalar(@{$new_feed_items}) == 0) {
        print "No new feed items found for feed $feed->{name}\n";
        print "Skipping . . .\n";
        next;
    }

    # Scan all new newsfeed items for selected keywords and
    # get only those matching the keywords
    my @result_feed_items = ();
    foreach my $feed_item (@{$new_feed_items}) {
        my @matched_categories = ();
        my @matched_tags = ();

        # Search categories
        foreach my $category (@categories) {
            if (($feed_item->{title} =~ /$category/i) or
                ($feed_item->{description} =~ /$category/i)) {
                    push @matched_categories, $category;
            }
        }

        # Search tags
        foreach my $tag (@tags) {
            if (($feed_item->{title} =~ /$tag/i) or
                ($feed_item->{description} =~ /$tag/i)) {
                    push @matched_tags, $tag;
            }
        }

        # Prepare and add result data record to result data set if we have
        # matched categories/matched tags
        my $item_rec = {};
        if (scalar(@matched_categories) > 0) {
            $item_rec->{categories} = \@matched_categories;
        }
        if (scalar(@matched_tags) > 0) {
            $item_rec->{tags} = \@matched_tags
        }

        if (%{$item_rec}) {
            $item_rec->{feed_data} = $feed_item;
            push @result_feed_items, $item_rec;
        }
    }

    # Process matched items and post them to WordPress
    # TODO

    print "Done.\n";
}

print "Finished processing feeds.\n";

# ------------------------------------------------------------------------------
#  F U N C T I O N S
# ------------------------------------------------------------------------------
#
# get_feed_data() - get feed
#
sub get_feed_data {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter required!';
    my $feed_conn_timeout = $feed->{conn_timeout} ||
        $config->{conn_timeout};

    my $user_agent = LWP::UserAgent->new;
    $user_agent->timeout($feed_conn_timeout);

    my $response = $user_agent->get($feed->{url});
    die 'Error while fetching RSS from ' . $feed->{url}
        unless ($response->is_success);

    my $feed_xml = $response->decoded_content;
    my $xs = XML::Simple->new(
        ForceArray => [ 'item' ],
    );
    my $feed_data = $xs->parse_string($feed_xml);
    return $feed_data;
}

# ------------------------------------------------------------------------------
#
# get_new_feed_items() - get feed items, check last update date/time for feed
# and get feeds only fresher than that time. If feed config parameter
# 'last_updated' is set, then use that date/time as last update time.
#
sub get_new_feed_items {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter required!';
    my $feed_data = $args{feed_data} or die 'feed_data parameter is required!';

    # Get feed record from feeds DB
    my $dbh = get_db();
    my $feed_db_rec = $dbh->selectrow_hashref(
        'SELECT * FROM feeds_data WHERE feed_id = ?',
        undef, ('rt')
    );

    my $feed_last_item_date_epoch = 0;
    my $feed_last_item_date_str = $feed_db_rec->{last_item_date};
    if (defined $feed_last_item_date_str and ($feed_last_item_date_str !~ /^\s*$/)) {
        $feed_last_item_date_epoch = 
            DateTime::Format::ISO8601->new()->parse_datetime(
                $feed_last_item_date_str)

    }

    # For every item in newsfeed check publication date and if newer than
    # last_item_date - add to new items list
    my @result_feed_items = ();
    foreach my $feed_item (@{$feed_data->{channel}{item}}) {
        my $item_datetime = DateTime::Format::RSS->new()->parse_datetime(
            $feed_item->{pubDate});

        if ($item_datetime->epoch() > $feed_last_item_date_epoch) {
            push @result_feed_items, $feed_item;
        }
    }
    return \@result_feed_items;
}

# ------------------------------------------------------------------------------
#
# get_db() - get feeds data DB handler. Returns standard DBI handler.
#
sub get_db {
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . FEEDS_DB_FILE ,"","") or
        die 'Cannot open SQLite database, file:  ' . FEEDS_DB_FILE;
    return $dbh;
}

