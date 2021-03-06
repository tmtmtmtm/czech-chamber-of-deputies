#!/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

require 'csv'
require 'nokogiri'
require 'open-uri'
require 'rest-client'
require 'scraperwiki'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

@API_URL = 'http://api.parldata.eu/cz/psp/%s'

def noko_q(endpoint, h)
  result = RestClient.get (@API_URL % endpoint), params: h, accept: :xml
  doc = Nokogiri::XML(result)
  doc.remove_namespaces!
  entries = doc.xpath('resource/resource')
  return entries if (np = doc.xpath('.//link[@rel="next"]/@href')).empty?
  [entries, noko_q(endpoint, h.merge(page: np.text[/page=(\d+)/, 1]))].flatten
end

def overlap(mem, term)
  mS = mem[:start_date].to_s.empty?  ? '0000-00-00' : mem[:start_date]
  mE = mem[:end_date].to_s.empty?    ? '9999-99-99' : mem[:end_date]
  tS = term[:start_date].to_s.empty? ? '0000-00-00' : term[:start_date]
  tE = term[:end_date].to_s.empty?   ? '9999-99-99' : term[:end_date]

  return unless mS < tE && mE > tS
  (s, e) = [mS, mE, tS, tE].sort[1, 2]
  {
    start_date: s == '0000-00-00' ? nil : s,
    end_date:   e == '9999-99-99' ? nil : e,
  }
end

ScraperWiki.sqliteexecute('DROP TABLE data') rescue nil

# http://api.parldata.eu/cz/psp/organizations?where={"classification":"chamber"}
xml = noko_q('organizations', where: %({"classification":"chamber"}))
xml.each do |chamber|
  term = {
    id:                   chamber.xpath('.//identifiers[scheme[text()="psp.cz/term"]]/identifier').text,
    identifier__parldata: chamber.xpath('.//id').text,
    start_date:           chamber.xpath('.//founding_date').text,
    end_date:             chamber.xpath('.//dissolution_date').text,
  }
  term[:name] = '%s. volební období' % term[:id]
  warn term[:name]
  ScraperWiki.save_sqlite([:id], term, 'terms')

  # http://api.parldata.eu/cz/psp/memberships?where={"organization_id":"165"}&embed=["person.memberships.organization"]
  mems = noko_q('memberships', where:       %({"organization_id":"#{term[:identifier__parldata]}"}),
                               max_results: 50,
                               embed:       '["person.memberships.organization"]')

  mems.each do |mem|
    person = mem.xpath('person')
    person.xpath('changes').each(&:remove) # make eyeballing easier
    psp_id = person.xpath('.//identifiers[scheme[text()="psp.cz/osoby"]]/identifier').text
    data = {
      id:                   psp_id,
      identifier__psp:      psp_id,
      identifier__parldata: person.xpath('id').text,
      name:                 person.xpath('name').text,
      sort_name:            person.xpath('sort_name').text,
      family_name:          person.xpath('family_name').text,
      given_name:           person.xpath('given_name').text,
      honorific_prefix:     person.xpath('honorific_prefix').text,
      birth_date:           person.xpath('birth_date').text,
      death_date:           person.xpath('death_date').text,
      gender:               person.xpath('gender').text,
      # email: person.xpath('email').text,
      # image: person.xpath('image').text,
      term:                 term[:id],
    }
    data.delete :sort_name if data[:sort_name] == ','

    mems = person.xpath('memberships[organization[classification[text()="political group"]]]').map do |m|
      {
        party:      m.xpath('organization/name').text,
        party_id:   m.xpath('.//identifiers[scheme[text()="psp.cz/organy"]]/identifier').text,
        start_date: m.xpath('start_date').text,
        end_date:   m.xpath('end_date').text,
      }
    end.select { |m| overlap(m, term) }

    if mems.count.zero?
      row = data.merge(party:      'Unknown', # or none?
                       party_id:   '_unknown',
                       start_date: '')
      # puts row.to_s
      ScraperWiki.save_sqlite(%i(id term), row)
    else
      mems.each do |mem|
        range = overlap(mem, term) or raise 'No overlap'
        row = data.merge(mem).merge(range)
        # puts row.to_s
        ScraperWiki.save_sqlite(%i(id term start_date), row)
      end
    end
  end
end
