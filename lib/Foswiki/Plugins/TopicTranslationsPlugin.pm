# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2009 Antonio Terceiro, terceiro@softwarelivre.org
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at 
# http://www.gnu.org/copyleft/gpl.html

# =========================
package Foswiki::Plugins::TopicTranslationsPlugin;

# =========================
use vars qw(
    $web $topic $user $installWeb $VERSION $RELEASE $pluginName
    $debug
    @translations
    $defaultLanguage
    $redirectMethod
    $userLanguage
    $acceptor
);

use I18N::AcceptLanguage;

# This should always be $Rev$ so that Foswiki can determine the checked-in
# status of the plugin. It is used by the build automation tools, so
# you should leave it alone.
$VERSION = '$Rev$';

# This is a free-form string you can use to "name" your own plugin version.
# It is *not* used by the build automation tools, but is reported as part
# of the version number in PLUGINDESCRIPTIONS.
$RELEASE = 'Dakar';

$pluginName = 'TopicTranslationsPlugin';  # Name of this Plugin

# =========================
sub initPlugin {
    ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if( $Foswiki::Plugins::VERSION < 1.024 ) {
        Foswiki::Func::writeWarning( "Version mismatch between $pluginName and Plugins.pm" );
        return 0;
    }

    # Get plugin debug flag
    $debug = Foswiki::Func::getPluginPreferencesFlag( "DEBUG" );

    # those should be preferably set in a per web basis. Defaults to the
    # corresponding plugin setting (or "en" if someone messes with it)
    my $trans = Foswiki::Func::getPreferencesValue("TOPICTRANSLATIONS") || Foswiki::Func::getPluginPreferencesValue("TOPICTRANSLATIONS") || "en";
    @translations = split(/,\s*/,$trans);
    $redirectMethod = Foswiki::Func::getPreferencesValue("REDIRECTMETHOD") || Foswiki::Func::getPluginPreferencesValue("REDIRECTMETHOD") || "http";
    $userLanguage = Foswiki::Func::getPreferencesValue("LANGUAGE") || "en";    

    # first listed language is the default one:
    $defaultLanguage = $translations[0];

    # create a language acceptor for later use:
    if($redirectMethod eq "http") {
        $acceptor = I18N::AcceptLanguage->new (
            strict => 0,
            defaultLanguage => $defaultLanguage
        );
    }

    # must I redirect to the best available translation?
    my $mustRedirect = (! Foswiki::Func::getPluginPreferencesFlag("DISABLE_AUTOMATIC_REDIRECTION"));
    checkRedirection() if $mustRedirect;

    # Plugin correctly initialized
    Foswiki::Func::writeDebug( "- Foswiki::Plugins::${pluginName}::initPlugin( $web.$topic ) is OK" ) if $debug;
    return 1;
}

# =========================
sub beforeCommonTagsHandler {
### my ( $text, $topic, $web ) = @_;   # do not uncomment, use $_[0], $_[1]... instead

    Foswiki::Func::writeDebug( "- ${pluginName}::beforeCommonTagsHandler( $_[2].$_[1] )" ) if $debug;

    # handle all INCLUDETRANSLATION tags:
    $_[0] =~ s/%INCLUDETRANSLATION{(.*?)}%/&handleIncludeTranslation($1)/ge;
}

# =========================
sub commonTagsHandler {
### my ( $text, $topic, $web ) = @_;   # do not uncomment, use $_[0], $_[1]... instead

    Foswiki::Func::writeDebug( "- ${pluginName}::commonTagsHandler( $_[2].$_[1] )" ) if $debug;

    # handle our common tags:
    $_[0] =~ s/%TRANSLATIONS({(.*?)})?%/&handleTranslations($2)/ge;
    $_[0] =~ s/%CURRENTLANGUAGE%/&currentLanguage/ge;
    $_[0] =~ s/%CURRENTLANGUAGESUFFIX%/&currentLanguageSuffix/ge;
    $_[0] =~ s/%DEFAULTLANGUAGE%/$defaultLanguage/ge;
    $_[0] =~ s/%BASETRANSLATION({(.*?)})?%/&handleBaseTranslation($2)/ge;
    $_[0] =~ s/%TRANSLATEMESSAGE({(.*?)})?%/&handleTranslateMessage($2)/ge;
}

# transform a language code into a suitable suffix for topics, by capitalizing
# the first letter and all the others lowercase.
# Examples:
#   pt-br -> Ptbr     EN -> En
#   pt_BR -> Ptbr     Pt -> Pt
#   EN-US -> Enus     pt -> Pt
sub normalizeLanguageName {
    my $lang = shift;
    $lang =~ s/[_-]//g;
    $lang =~ s/^(.)(.*)$/\u$1\L$2/;
    return $lang;
}

# finds the base topic name, i.e., the topic name without any language suffix.
# If no topic is passed as argument, uses $topic (the topic from which the
# plugin is being called).
sub findBaseTopicName {
    my $base = shift || $topic;
    foreach $lang (@translations) {
        $norm = normalizeLanguageName($lang);
        if ($base =~ m/$norm$/) {
            $base =~ s/$norm$//;
        }
    }
    return $base;
}

# finds the language of the current topic (or of the topic passed in as
# argument), based on its suffix
sub currentLanguage {
    my $theTopic = shift || $topic;
    my $norm;
    foreach $lang (@translations) {
        $norm = normalizeLanguageName($lang);
        if ($theTopic =~ m/$norm$/) {
            return $lang;
        }
    }
    return $defaultLanguage;
}

# returns the current language suffix, or '' (empty string) if the current
# language is the default one
sub currentLanguageSuffix {
  my $lang = currentLanguage();
  return ($lang eq $defaultLanguage) ? '' : normalizeLanguageName($lang);
}

# list the translations of the current topic (or to that one passed as an
# argument). Depending on the arguments to the %TRANSLATIONS% tag, many options
# can apply.
sub handleTranslations {
    my $params = shift;

    my $result = "";
    my $separator = "";
    my $norm;

    # format for the items:
    my $format = Foswiki::Func::extractNameValuePair($params, "format") || "[[\$web.\$translation][\$language]]";
    my $missingFormat = Foswiki::Func::extractNameValuePair($params, "missingformat") || $format;
    
    # other stuff:
    my $userSeparator = Foswiki::Func::extractNameValuePair($params, "separator") || " ";

    # 
    my $theTopic = Foswiki::Func::extractNameValuePair($params) || Foswiki::Func::extractNameValuePair($params,"topic") || $topic;
    my $theWeb;
    if ($theTopic =~ m/^([^.]+)\.([^.]+)/) {
        # topic="Web.MyTopic"
        $theWeb = $1;
        $theTopic = $2;
    } else {
        $theWeb = $web;
    }
    my $baseTopicName = findBaseTopicName($theTopic);

    # find out which translations we must list:
    my $which = Foswiki::Func::extractNameValuePair($params, "which") || "all";
    my @whichTranslations;
    if ($which eq "available") {
        @whichTranslations = findAvailableTranslations($theTopic);
    } elsif ($which eq "missing") {
        @whichTranslations = findMissingTranslations($theTopic);
    } else {
        @whichTranslations = @translations;
    }
 
    # list translations
    foreach $lang (@whichTranslations) {
        $norm = ($lang eq $defaultLanguage)?'':normalizeLanguageName($lang);
        $result .= $separator;
        $separator = $userSeparator;
        $result .= formatTranslationEntry($baseTopicName, $theWeb, $baseTopicName . $norm, $lang, $format, $missingFormat);
    }

    return $result;
}

# shows the item using the given format
sub formatTranslationEntry {
    my ($theTopic, $theWeb, $translationTopic, $lang, $format, $missingFormat) = @_;

    # wheter to use the format for available translations or for missing ones:
    my $result = (Foswiki::Func::topicExists($web, $translationTopic))?($format):($missingFormat);

    # substitute the variables:
    $result =~ s/\$web/$theWeb/g;
    $result =~ s/\$topic/$theTopic/g;
    $result =~ s/\$translation/$translationTopic/g;
    $result =~ s/\$language/$lang/g;

    return $result;
}

# include the translation of the given topic that corresponds to our current
# language
sub handleIncludeTranslation {
    my $params = shift;

    my $theLang = currentLanguage();
    
    my $theTopic = Foswiki::Func::extractNameValuePair($params);
    my $theWeb;
    if ($theTopic =~ m/^([^.]+)\.([^.]+)/) {
        # topic="Web.MyTopic"
        $theWeb = $1;
        $theTopic = $2;
    } else {
        $theWeb = $web;
    }
    $theTopic = findBaseTopicName($theTopic);

    if ($theLang ne $defaultLanguage) {
        $theTopic .= normalizeLanguageName($theLang);
    }

    # undef is ok, meaning current revision:
    my $theRev = Foswiki::Func::extractNameValuePair($params, "rev");

    my $args = "\"$theWeb.$theTopic\"";
    $args .= " rev=\"$theRev\"" if $theRev;

    return '%INCLUDE{' . $args . '}%';
}

# finds the best suitable translation to the current topic (or, alternatively,
# to the topic passsed as the first parameter)
sub findBestTranslation {
    my $theTopic = shift || $topic;
    my @alternatives = findAvailableTranslations($theTopic);
    my $best=$defaultLanguage;
    if ($redirectMethod eq "user"){
        foreach $lang (@alternatives){
            $best=$lang if $userLanguage eq $lang;
        }
    } else { # $redirectMethod is http or anything else
        $best=$acceptor->accepts($ENV{HTTP_ACCEPT_LANGUAGE}, \@alternatives);
    }
    return $best;
}

# check if a redirection is needed, possible, and do that if it's the case
sub checkRedirection {
    # we only want to be redirected in view or viewauth, and when there is no
    # extra parameters to the request:

    # fake to '/view' if no script name (e.g. when using shorter URL's)
    my $script = $ENV{SCRIPT_NAME} || '/view'; 

    if (($script =~ m/\/view(auth)?$/) and (! $ENV{QUERY_STRING})) {
        my $query = Foswiki::Func::getCgiQuery();
    
        # several checks
        my $baseTopicName = findBaseTopicName();
        my $baseUrl = Foswiki::Func::getViewUrl($web, $baseTopicName);
        my $editUrl = Foswiki::Func::getScriptUrl($web, $baseTopicName, 'edit');
        my $origin = $query->referer() || '';
        my $originLanguage = currentLanguage($origin);

        my $current = currentLanguage();

        # don't redirect if we came from another topic in the same language as
        # the current one.
        if ($origin && $originLanguage eq $current) {
          return;
        }
        
        # we don't want to redirect if the user came from another translation of
        # this same topic, or from an edit
        if ( (!($origin =~ /^$baseUrl/)) and (!($origin =~ /^$editUrl/))) {

            # check where we are:
            my $best = findBestTranslation(); # for the current topic, indeed

            # we don't need to redirect if we are already in the best translation:
            if (($current ne $best)) {
              # actually do the redirect:
              my $bestTranslationTopic = findBaseTopicName() . (($best eq $defaultLanguage)?'':(normalizeLanguageName($best)));
              my $url = Foswiki::Func::getViewUrl($web,$bestTranslationTopic);
              Foswiki::Func::redirectCgiQuery($query, $url);
            }
        }
    }
}

# find the translations that already exist for the given topic, if any,
# or for $topic, if no topic is informed.
sub findAvailableTranslations {
    return findTranslations(1, (shift || $topic));
}

# find the translations that doesnt' exist yet for the given topic, if any, or
# for $topic, if no topic is informed.
sub findMissingTranslations {
    return findTranslations(0, (shift || $topic));
}

# find translations that exists or are missing, depending on the first
# parameter (call it $existance):
# * if $existance evaluates to TRUE, find translations that do exist
# * if $existance evaluates to FALSE, find translations that DON'T exit
sub findTranslations {
    my $existance = shift;

    $theTopic = shift || $topic;
    $theTopic = findBaseTopicName($theTopic);

    my ($norm, $exists);
    my @items;

    foreach $lang (@translations) {
        # the suffix is empty in the case of the default language:
        $norm = ($lang eq $defaultLanguage)?(""):(normalizeLanguageName($lang));
        
        # is that translation available?
        $exists = Foswiki::Func::topicExists($web, $theTopic . $norm);

        # what kind (available or not) are we looking for?
        if (($existance and $exists) or ((!$existance) and (!$exists))) {
            push(@items, $lang);
        }
    }
    
    return @items;
}

sub handleBaseTranslation {
    my $params = shift;
    my $myTopic = Foswiki::Func::extractNameValuePair($params, "topic") || $topic;
    return findBaseTopicName($myTopic);
}


sub handleTranslateMessage {
  my $params = shift;
  my $lang = currentLanguage();
  return (Foswiki::Func::extractNameValuePair($params, $lang));
}

# =========================

1;
