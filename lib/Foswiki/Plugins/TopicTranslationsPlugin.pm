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

use strict;
use warnings;

use Foswiki::Func ();

use constant DEBUG => 0;    # toggle me

our @translations;
our $defaultLanguage;
our %normalizedTranslations;
our $baseWeb;
our $baseTopic;
our $acceptor;

our $VERSION = '2.00';
our $RELEASE = '2.00';

our $NO_PREFS_IN_TOPIC = 1;

# =========================
sub initPlugin {
  ($baseTopic, $baseWeb) = @_;

  # check for Plugins.pm versions
  if ($Foswiki::Plugins::VERSION < 1.024) {
    Foswiki::Func::writeWarning("Version mismatch between TopicTranslationsPlugin and Plugins.pm");
    return 0;
  }

  # those should be preferably set in a per web basis. Defaults to the
  # corresponding plugin setting (or "en" if someone messes with it)
  my $trans = Foswiki::Func::getPreferencesValue("TOPICTRANSLATIONS") || "en";
  chomp $trans;
  @translations = split(/\s*,\s*/, $trans);
  normalizeLanguageName($_) foreach @translations;
  $defaultLanguage = $translations[0];

  # must I redirect to the best available translation?
  checkRedirection()
    unless Foswiki::Func::isTrue(Foswiki::Func::getPreferencesFlag("DISABLE_AUTOMATIC_REDIRECTION"));

  Foswiki::Func::registerTagHandler('INCLUDETRANSLATION', \&handleIncludeTranslation);
  Foswiki::Func::registerTagHandler('BASETRANSLATION', \&handleBaseTranslation);
  Foswiki::Func::registerTagHandler('TRANSLATIONS', \&handleTranslations);
  Foswiki::Func::registerTagHandler('TRANSLATEMESSAGE', sub { return $_[1]->{currentLanguage()}; });
  Foswiki::Func::registerTagHandler('DEFAULTLANGUAGE', sub { return $defaultLanguage; });
  Foswiki::Func::registerTagHandler('CURRENTLANGUAGE', sub { return currentLanguage(); });
  Foswiki::Func::registerTagHandler('CURRENTLANGUAGESUFFIX', sub { return currentLanguageSuffix(); });

  return 1;
}

# transform a language code into a suitable suffix for topics, by capitalizing
# the first letter and all the others lowercase.
# Examples:
#   pt-br -> Ptbr     EN -> En
#   pt_BR -> Ptbr     Pt -> Pt
#   EN-US -> Enus     pt -> Pt
sub normalizeLanguageName {
  my $lang = shift;

  my $norm = $normalizedTranslations{$lang};

  unless (defined $norm) {
    $norm = $lang;
    $norm =~ s/[_-]//g;
    $norm =~ s/^(.)(.*)$/\u$1\L$2/;
    $normalizedTranslations{$lang} = $norm;
  }

  return $norm;
}

# finds the base topic name, i.e., the topic name without any language suffix.
# If no topic is passed as argument, uses $baseTopic (the topic from which the
# plugin is being called).
sub findBaseTopicName {
  my $base = shift || $baseTopic;

  foreach my $lang (values %normalizedTranslations) {
    last if $base =~ s/$lang$//;
  }

  return $base;
}

# finds the language of the current topic (or of the topic passed in as
# argument), based on its suffix
sub currentLanguage {
  my $theTopic = shift || $baseTopic;

  foreach my $lang (keys %normalizedTranslations) {
    my $norm = $normalizedTranslations{$lang};
    return $lang if $theTopic =~ m/$norm$/;
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
  my ($session, $params, $topic, $web) = @_;

  # format for the items:
  my $format = $params->{format} || "[[\$web.\$translation][\$language]]";
  my $missingFormat = $params->{missingformat} || $format;

  # other stuff:
  my $theSep = $params->{separator};
  $theSep = ", " unless defined $theSep;

  my ($theWeb, $theTopic) = Foswiki::Func::normalizeWebTopicName($web, $params->{_DEFAULT} || $params->{topic} || $topic);
  my $baseTopicName = findBaseTopicName($theTopic);

  # find out which translations we must list:
  my $which = $params->{which} || "all";
  my @whichTranslations;
  if ($which eq "available") {
    @whichTranslations = findAvailableTranslations($theTopic);
  } elsif ($which eq "missing") {
    @whichTranslations = findMissingTranslations($theTopic);
  } else {
    @whichTranslations = @translations;
  }

  # list translations
  my @result = ();
  foreach my $lang (@whichTranslations) {
    my $norm = ($lang eq $defaultLanguage) ? '' : normalizeLanguageName($lang);
    push @result, formatTranslationEntry($baseTopicName, $theWeb, $baseTopicName . $norm, $lang, $format, $missingFormat);
  }

  return join($theSep, @result);
}

# shows the item using the given format
sub formatTranslationEntry {
  my ($theTopic, $theWeb, $translationTopic, $lang, $format, $missingFormat) = @_;

  # wheter to use the format for available translations or for missing ones:
  my $result = (Foswiki::Func::topicExists($baseWeb, $translationTopic)) ? ($format) : ($missingFormat);

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
  my ($session, $params, $topic, $web) = @_;

  my ($theWeb, $theTopic) = Foswiki::Func::normalizeWebTopicName($web, $params->{_DEFAULT} || $params->{topic} || $topic);
  $theTopic = findBaseTopicName($theTopic);

  my $theLang = currentLanguage();

  if ($theLang ne $defaultLanguage) {
    $theTopic .= normalizeLanguageName($theLang);
  }

  my $theRev = $params->{rev};

  my $args = "\"$theWeb.$theTopic\"";
  $args .= " rev=\"$theRev\"" if $theRev;

  return '%INCLUDE{' . $args . '}%';
}

# finds the best suitable translation to the current topic (or, alternatively,
# to the topic passsed as the first parameter)
sub findBestTranslation {
  my $theTopic = shift || $baseTopic;
  my @alternatives = findAvailableTranslations($theTopic);
  my $best = $defaultLanguage;
  my $redirectMethod = Foswiki::Func::getPreferencesValue("REDIRECTMETHOD") || "http";
  if ($redirectMethod eq "user") {
    my $userLanguage = Foswiki::Func::getPreferencesValue("LANGUAGE") || "en";
    foreach my $lang (@alternatives) {
      $best = $lang if $userLanguage eq $lang;
    }
  } else {    # $redirectMethod is http or anything else
    unless (defined $acceptor) {
      require I18N::AcceptLanguage;
      $acceptor = I18N::AcceptLanguage->new(
        strict => 0,
        defaultLanguage => $defaultLanguage
      );
    }

    my $acceptLanguage = Foswiki::Func::getCgiQuery()->header("Accept-Language");
    $best = $acceptor->accepts($acceptLanguage, \@alternatives);
  }
  return $best;
}

# check if a redirection is needed, possible, and do that if it's the case
sub checkRedirection {

  my $query = Foswiki::Func::getCgiQuery();
  my $script = $query->action();
  my $queryString = $query->queryString();

  # we only want to be redirected in view or viewauth, and when there is no
  # extra parameters to the request:
  if ($script !~ m/view(auth)?$/ or $queryString) {
    Foswiki::Func::writeDebug("TopicTranslationsPlugin - not redirecting: action != view or there's a query string") if DEBUG;
    return;
  }

  # don't redirect when called on the command line
  return if $Foswiki::Plugins::SESSION->inContext('command_line');

  # several checks
  my $baseTopicName = findBaseTopicName();
  my $baseUrl = Foswiki::Func::getViewUrl($baseWeb, $baseTopicName);
  my $editUrl = Foswiki::Func::getScriptUrl($baseWeb, $baseTopicName, 'edit');
  my $origin = $query->referer() || '';
  my $originLanguage = currentLanguage($origin);

  my $current = currentLanguage();
  Foswiki::Func::writeDebug("TopicTranslationsPlugin - origin=$origin, originLanguage=$originLanguage, current=$current, baseUrl=$baseUrl") if DEBUG;

  # don't redirect if we came from another topic in the same language as
  # the current one.
  if ($origin && $originLanguage eq $current) {
    Foswiki::Func::writeDebug("TopicTranslationsPlugin - not redirecting: coming from a topic in the same language") if DEBUG;
    return;
  }

  # we don't want to redirect if the user came from another translation of
  # this same topic, or from an edit
  if (!($origin =~ /^$baseUrl/) && !($origin =~ /^$editUrl/)) {

    # check where we are:
    my $best = findBestTranslation();    # for the current topic, indeed
    Foswiki::Func::writeDebug("TopicTranslationsPlugin - best translation = $best") if DEBUG;

    # we don't need to redirect if we are already in the best translation:
    if ($current ne $best) {
      # actually do the redirect:
      my $bestTranslationTopic = findBaseTopicName() . (($best eq $defaultLanguage) ? '' : (normalizeLanguageName($best)));
      my $url = Foswiki::Func::getViewUrl($baseWeb, $bestTranslationTopic);
      Foswiki::Func::writeDebug("TopicTranslationsPlugin - redirecting to $url") if DEBUG;
      Foswiki::Func::redirectCgiQuery($query, $url);
    }
  }
}

# find the translations that already exist for the given topic, if any,
# or for $baseTopic, if no topic is informed.
sub findAvailableTranslations {
  return findTranslations(1, (shift || $baseTopic));
}

# find the translations that doesnt' exist yet for the given topic, if any, or
# for $baseTopic, if no topic is informed.
sub findMissingTranslations {
  return findTranslations(0, (shift || $baseTopic));
}

# find translations that exists or are missing, depending on the first
# parameter (call it $existance):
# * if $existance evaluates to TRUE, find translations that do exist
# * if $existance evaluates to FALSE, find translations that DON'T exit
sub findTranslations {
  my $existance = shift;

  my $theTopic = shift || $baseTopic;
  $theTopic = findBaseTopicName($theTopic);

  my ($norm, $exists);
  my @items;

  foreach my $lang (@translations) {
    # the suffix is empty in the case of the default language:
    $norm = ($lang eq $defaultLanguage) ? ("") : (normalizeLanguageName($lang));

    # is that translation available?
    $exists = Foswiki::Func::topicExists($baseWeb, $theTopic . $norm);

    # what kind (available or not) are we looking for?
    if (($existance and $exists) or ((!$existance) and (!$exists))) {
      push(@items, $lang);
    }
  }

  return @items;
}

sub handleBaseTranslation {
  my ($session, $params, $topic, $web) = @_;

  my $theTopic = $params->{_DEFAULT} || $params->{topic} || $topic;
  return findBaseTopicName($theTopic);
}

# =========================

1;
