#!/usr/bin/perl -w
# 
# feedposter.pl - a script that does 2 things:
#     1) process RSS feed and get all articles that have specified keywords;
#     2) get HTML-only version of an article
#     3) post to Wordpress blog
#

use strict;
use utf8;

use DateTime::Format::ISO8601;
use DateTime::Format::RSS;
use DateTime::Format::SQLite;
use Data::Dumper;
use DBI;
use Getopt::Long;
use HTML::Restrict;
use LWP::UserAgent;
use POSIX qw( strftime );
use WordPress::XMLRPC;
use XML::Simple;
use YAML qw( LoadFile );

use constant CONFIG_FILE => 'feedposter.yaml';
use constant DEBUG => 1;
use constant FEEDS_DB_FILE => 'feeds_data.db';

# Read options
my $options = {};
GetOptions(
    'config=s' => \$options->{config},
    'help' => \$options->{help}
);

# If help info request - show program usage info
if ($options->{'help'}) {
    print_usage();
    exit(0);
}

# Check config file. If --config option supplied - load
# configuration fromn that file. Otherwise - try default config.
# If not found - exit with usage info.
my $config = '';
if (-f $options->{config}) {
    $config = LoadConfig($options->{config});

} elsif (-f CONFIG_FILE) {
    # Now try default config
    $config = LoadFile(CONFIG_FILE);

}else {
    # No config file found - print usage and exit with error
    print_usage();
    exit(1);
}

my $blog_config = $config->{blog};

# Say hi
print_version();

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

printf("Done, got %d categories, %d tags\n", scalar(@categories), scalar(@tags));

# Process feeds
my @feeds = @{$config->{feeds}};

unless (scalar(@feeds)) {
    print "\nNo feeds to process!\nPlease edit config file feedposter.yaml\n\n";
    exit(0);
}

print "Processing feeds, " . scalar(@feeds) . " to process\n";

foreach my $feed (@feeds) {
    print "Processing feed $feed->{name} . . .\n";
    $feed->{processed_at} = time();
    
    # Get RSS feed items
    my $feed_data = get_feed_data(feed => $feed);

    # Get last update date/time for a feed and get all articles
    # newer than that date
    print "Getting new feed items . . .\n";
    my $new_feed_items = get_new_feed_items(
        feed => $feed,
        feed_data => $feed_data
    );
    if (scalar(@$new_feed_items) == 0) {
        print "No new feed items found for feed $feed->{name}\n";
        print "Skipping\n";
        next;

    } else {
        printf("Done, found %d new feed items\n", scalar(@$new_feed_items));
    }

    # Scan all new newsfeed items for selected keywords and
    # get only those matching the keywords
    print "Matching feed items against blog categories and tags . . .\n";
    my $result_feed_items =
        match_feed_items(feed_items => $new_feed_items);
    printf("Done, %d feed items matched\n", scalar(@$result_feed_items));

    # Process matched items and post them to WordPress
    if (scalar(@$result_feed_items) > 0) {
        print "Posting new feed items to blog . . .\n";
        foreach my $item_rec (@$result_feed_items) {
            post_feed_item_to_blog(feed => $feed, item_rec => $item_rec);
        }
        print "Done posting\n";
    }

    # If we have feed items to post to blog - record date of last
    # processed newsfeed item date and feed last processed time in DB.
    if (scalar(@$result_feed_items) > 0) {
        update_feed_db_data(
            feed => $feed,
            feed_data => $feed_data
        );
        print "Updated feed DB data\n";
    }

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
    my $feed = $args{feed} or die 'feed parameter required';
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
    my $feed = $args{feed} or die 'feed parameter required';
    my $feed_data = $args{feed_data} or die 'feed_data parameter is required';

    # Get feed record from feeds DB
    my $dbh = get_db();
    my $feed_db_rec = $dbh->selectrow_hashref(
        'SELECT * FROM feeds_data WHERE feed_id = ?',
        undef, $feed->{id}
    );

    my $last_processed_at = 0;
    my $last_processed_at_str = $feed_db_rec->{last_processed_at};
    if (defined $last_processed_at_str and ($last_processed_at_str !~ /^\s*$/)) {
        $last_processed_at = 
            DateTime::Format::SQLite->new()->parse_datetime(
                $last_processed_at_str)->epoch();

    }

    # For every item in newsfeed check publication date and if newer than
    # last_processed_at - add to new items list
    my @result_feed_items = ();
    foreach my $feed_item (@{$feed_data->{channel}{item}}) {
        my $item_pubdate = DateTime::Format::RSS->new()->parse_datetime(
            $feed_item->{pubDate})->epoch();

        if ($item_pubdate > $last_processed_at) {
            $feed_item->{pubDateEpoch} = $item_pubdate;
            push @result_feed_items, $feed_item;
        }
    }

    return \@result_feed_items;
}

# ------------------------------------------------------------------------------
#
# feed_item_preprocess() - pre-process feed item data for blog-posting
#
sub feed_item_preprocess {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter required';
    my $feed_item = $args{feed_item} or die 'feed_item parameter required';

    # Decode from internal UTF-8 representation (encode to charset UTF-8)
    utf8::encode($feed_item->{title});
    utf8::encode($feed_item->{description});

    # Strip ALL HTML tags from feed item text
    {
        my $hr = HTML::Restrict->new();
        $feed_item->{description} = $hr->process($feed_item->{description});
    }

    # Add link and enclosure (if set and is of type 'image/*') to source article
    {
        my $article_header = "From <a href=\"$feed_item->{link}\" target=\"_new\">$feed->{name}</a>:<br /><br />\n\n";
        if (exists $feed_item->{enclosure}) {
            if ($feed_item->{enclosure}{type} =~ /^image/) {
                $article_header .= "<img src=\"$feed_item->{enclosure}{url}\" />\n\n"
            }
        }
        $feed_item->{description} = $article_header . $feed_item->{description};
    }
}

# ------------------------------------------------------------------------------
# 
# match_feed_items() - match feed items against categories and tags
#
sub match_feed_items {
    my %args = @_;
    my $feed_items = $args{feed_items} or
        die 'feed_items parameter required';

    my @result_feed_items = ();
    foreach my $feed_item (@$feed_items) {
        my @matched_categories = ();
        my @matched_tags = ();

        # Search categories
        foreach my $category (@categories) {
            if (($feed_item->{title} =~ /\b$category\b/i) or
                ($feed_item->{description} =~ /\b$category\b/i)) {
                    push @matched_categories, $category;
            }
        }

        # Search tags
        foreach my $tag (@tags) {
            if (($feed_item->{title} =~ /\b$tag\b/i) or
                ($feed_item->{description} =~ /\b$tag\b/i)) {
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
            $item_rec->{feed_item} = $feed_item;
            $item_rec->{categories} = [] unless (exists $item_rec->{categories});
            $item_rec->{tags} = [] unless (exists $item_rec->{tags});
            push @result_feed_items, $item_rec;
        }
    }

    return \@result_feed_items;
}

# ------------------------------------------------------------------------------
#
# post_feed_item_to_blog() - post feed item to blog, that's all that it does
#
sub post_feed_item_to_blog {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter required';
    my $item_rec = $args{item_rec} or die 'item_rec parameter required';
    my $feed_item = $item_rec->{feed_item};

    feed_item_preprocess(feed => $feed, feed_item => $feed_item);

    my %post_data = (
        categories => [ 'Uncategorized', @{$item_rec->{categories}} ],
        dateCreated => strftime("%Y%m%dT%H:%M:%S",
            localtime($feed_item->{pubDateEpoch})),
        post_status => 'publish',
        post_type => 'post',
        post_format => 'standard',
        title => $feed_item->{title},
        mt_excerpt => '',
        description => $feed_item->{description},
        mt_allow_comments => 'open',
        mt_allow_pings => 'open',
        mt_keywords => $item_rec->{tags},
        sticky => 0
    );
    print "---\n";
    print "Title: $post_data{title}\n";
    print "Date: $post_data{dateCreated}\n";
    $wp->newPost(\%post_data, 1) or die $wp->errstr();
}

# ------------------------------------------------------------------------------
#
# update_feed_db_data() - update feed DB data (last feed item date,
# last feed processed date, etc)
#
sub update_feed_db_data {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter is required';

    my $last_processed_at = strftime("%Y-%m-%d %H:%M:%S",
        localtime($feed->{processed_at}));
    print "Feed last processed date: $last_processed_at\n";

    my $dbh = get_db();
    my $rec = $dbh->selectrow_hashref(
        'SELECT * FROM feeds_data WHERE feed_id = ?', undef, $feed->{id});
    unless (defined $rec) {
        $dbh->do('INSERT INTO feeds_data VALUES (?, ?)', undef,
            $feed->{id}, $last_processed_at);
    } else {
        $dbh->do('UPDATE feeds_data SET last_processed_at = ?' .
            ' WHERE feed_id = ?', undef, $last_processed_at, $feed->{id});
    }
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

# ------------------------------------------------------------------------------
#
# print_version - print program version
#
sub print_version {
    print "\nFeedPoster - v1.0\n\n";
}

# ------------------------------------------------------------------------------
# 
# print_usage - print usage info
#
sub print_usage {
    print_version();
    print <<USAGE_INFO;
Usage:

    feedposter.pl --config <config file path>

USAGE_INFO
}

