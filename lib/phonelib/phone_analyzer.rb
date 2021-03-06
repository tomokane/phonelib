module Phonelib
  # @private phone analyzing methods module
  module PhoneAnalyzer
    # extending with helper methods for analyze
    include Phonelib::PhoneAnalyzerHelper

    # array of types not included for validation check in cycle
    NOT_FOR_CHECK = [:general_desc, :fixed_line, :mobile, :fixed_or_mobile]

    # parses provided phone if it is valid for  country data and
    # returns result of analyze
    #
    # ==== Attributes
    #
    # * +phone+ - Phone number for parsing
    # * +passed_country+ - Country provided for parsing. Must be ISO code of
    #   country (2 letters) like 'US', 'us' or :us for United States
    def analyze(phone, passed_country)
      country = country_or_default_country passed_country

      result = try_to_parse_country(phone, country)
      d_result = case
                 when result && result.values.find {|e| e[:valid].any? }
                   # all is good, return result
                 when passed_country.nil?
                   # trying for all countries if no country was passed
                   detect_and_parse phone
                 when !original_string.start_with?('+') && country_can_double_prefix?(country)
                   # if country allows double prefix trying modified phone
                   try_to_parse_country(changed_double_prefixed_phone(country, phone), country)
                 end
      better_result(result, d_result)
    end

    private

    # method checks which result is better to return
    def better_result(base_result, result = nil)
      if result.nil?
        return base_result || {}
      end

      if base_result.nil? || base_result.empty? || base_result.values.find {|e| e[:possible].any? }.nil?
        return result
      end

      if result && result.values.find {|e| e[:valid].any? }
        return result
      end

      base_result || {}
    end

    # trying to parse phone for single country including international prefix
    # check for provided country
    #
    # ==== Attributes
    #
    # * +phone+ - phone for parsing
    # * +country+ - country to parse phone with
    def try_to_parse_country(phone, country)
      data = Phonelib.phone_data[country]
      return nil unless country && data

      # if country was provided and it's a valid country, trying to
      # create e164 representation of phone number,
      # kind of normalization for parsing
      e164 = convert_to_e164 phone, data
      # if phone starts with international prefix of provided
      # country try to reanalyze without international prefix for
      # all countries
      return analyze(e164.delete('+'), nil) if e164[0] == '+'
      # trying to parse number for provided country
      parse_single_country e164, data
    end

    # method checks if phone is valid against single provided country data
    #
    # ==== Attributes
    #
    # * +e164+ - e164 representation of phone for parsing
    # * +data+ - country data for single country for parsing
    def parse_single_country(e164, data)
      valid_match = phone_match_data?(e164, data)
      if valid_match
        national_and_data(e164, data, valid_match)
      else
        possible_match = phone_match_data?(e164, data, true)
        possible_match && national_and_data(e164, data, possible_match, true)
      end
    end

    # method tries to detect what is the country for provided phone
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    def detect_and_parse(phone)
      result = {}
      Phonelib.phone_data.each do |key, data|
        parsed = parse_single_country(phone, data)
        if double_prefix_allowed?(data, phone, parsed && parsed[key])
          parsed = parse_single_country(changed_double_prefixed_phone(key, phone), data)
        end
        result.merge!(parsed) unless parsed.nil?
      end
      result
    end

    # Create phone representation in e164 format
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+  - country data to be based on for creating e164 representation
    def convert_to_e164(phone, data)
      match = phone.match full_regex_for_data(data, Core::VALID_PATTERN)
      case
      when match
        national_start = phone.length - match.to_a.last.size
        "#{data[Core::COUNTRY_CODE]}#{phone[national_start..-1]}"
      when phone.match(cr("^#{data[Core::INTERNATIONAL_PREFIX]}"))
        phone.sub(cr("^#{data[Core::INTERNATIONAL_PREFIX]}"), '+')
      else
        "#{data[Core::COUNTRY_CODE]}#{phone}"
      end
    end

    # returns national number and analyzing results for provided phone number
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+ - country data
    # * +country_match+ - result of match of phone within full regex
    # * +not_valid+ - specifies that number is not valid by general desc pattern
    def national_and_data(phone, data, country_match, not_valid = false)
      prefix_length = data[Core::COUNTRY_CODE].length
      prefix_length += [1, 2].map { |i| country_match[i].to_s.size }.inject(:+)
      result = data.select { |k, _v| k != :types && k != :formats }
      result[:national] = phone[prefix_length..-1] || ''
      result[:format] = number_format(result[:national], data[Core::FORMATS])
      result.merge! all_number_types(result[:national], data[Core::TYPES],
                                     not_valid)
      result[:valid] = [] if not_valid

      { result[:id] => result }
    end

    # Returns all valid and possible phone number types for currently parsed
    # phone for provided data hash.
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+  - country data
    # * +not_valid+ - specifies that number is not valid by general desc pattern
    def all_number_types(phone, data, not_valid = false)
      response = { valid: [], possible: [] }

      types_for_check(data).each do |type|
        possible, valid = get_patterns(data, type)

        valid_and_possible, possible_result =
            number_valid_and_possible?(phone, possible, valid, not_valid)
        response[:possible] << type if possible_result
        response[:valid] << type if valid_and_possible
      end

      sanitize_fixed_mobile(response)
    end

    # Gets matched number formatting rule or default one
    #
    # ==== Attributes
    #
    # * +national+ - national phone number
    # * +format_data+  - formatting data from country data
    def number_format(national, format_data)
      format_data && format_data.find do |format|
        (format[Core::LEADING_DIGITS].nil? \
          || national.match(cr("^(#{format[Core::LEADING_DIGITS]})"))) \
        && national.match(cr("^(#{format[Core::PATTERN]})$"))
      end || Core::DEFAULT_NUMBER_FORMAT
    end

    # Returns possible and valid patterns for validation for provided type
    #
    # ==== Attributes
    #
    # * +all_patterns+ - hash of all patterns for validation
    # * +type+ - type of phone to get patterns for
    def get_patterns(all_patterns, type)
      type = Core::FIXED_LINE if type == Core::FIXED_OR_MOBILE
      patterns = all_patterns[type]

      if patterns.nil?
        [nil, nil]
      else
        [patterns[Core::POSSIBLE_PATTERN], patterns[Core::VALID_PATTERN]]
      end
    end
  end
end
