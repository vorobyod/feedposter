#!/usr/bin/perl -w
# 
# feedposter.pl - a script that does 2 things:
#     1) process RSS feed and get all articles that have specified keywords;
#     2) get HTML-only version of an article
#     3) post to Wordpress blog
#

use strict;

use Data::Dumper;
use LWP::UserAgent;
use XML::Simple;

my $config = {
    conn_timeout => 10,
    feeds => [
        {
            name => 'Russia Today',
            url => 'http://rt.com/news/today/rss/'
        }
    ]
};

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
    my @new_feed_items = get_new_feed_items(
        feed => $feed,
        feed_data => $feed_data
    );
    if (scalar(@new_feed_items) == 0) {
        print "No new feed items found for feed $feed->{name}\n";
        print "Skipping . . .\n";
        next;
    }

    # Scan all new newsfeed items for selected keywords and
    # get only those matching the keywords
    # TODO

    # Process matched items and post them to WordPress
    # TODO

    print "Done.\n";
}

print "Finished processing feeds.\n";

# ------------------------------------------------------------------------------
#  F U N C T I O N S
# ------------------------------------------------------------------------------
#
# Get feed
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
# Get new feed items - check last update date/time for feed and get feeds only
# fresher than that time. If feed config parameter 'last_updated' is set, then
# use that date/time as last update date.
#
sub get_new_feed_items {
    my %args = @_;
    my $feed = $args{feed} or die 'feed parameter required!';
    my $feed_data = $args{feed_data} or die 'feed_data parameter is required!';
    # TODO
    die 'Not implemented!';
}

