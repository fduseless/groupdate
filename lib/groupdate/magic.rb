module Groupdate
  class Magic
    attr_accessor :field, :options

    def initialize(field, options)
      @field = field
      @options = options

      if !time_zone
        raise "Unrecognized time zone"
      end

      if field == :week and !week_start
        raise "Unrecognized :week_start option"
      end
    end

    def group_by(enum, &block)
      series(enum.group_by{|v| v2 = block.call(v); v2 ? round_time(v2) : nil }, [])
    end

    def relation(column, relation)
      column = relation.connection.quote_table_name(column)
      time_zone = self.time_zone.tzinfo.name

      adapter_name = relation.connection.adapter_name
      query =
        case adapter_name
        when "MySQL", "Mysql2"
          case field
          when :day_of_week # Sunday = 0, Monday = 1, etc
            # use CONCAT for consistent return type (String)
            ["DAYOFWEEK(CONVERT_TZ(DATE_SUB(#{column}, INTERVAL #{day_start} HOUR), '+00:00', ?)) - 1", time_zone]
          when :hour_of_day
            ["(EXTRACT(HOUR from CONVERT_TZ(#{column}, '+00:00', ?)) + 24 - #{day_start}) % 24", time_zone]
          when :week
            ["CONVERT_TZ(DATE_FORMAT(CONVERT_TZ(DATE_SUB(#{column}, INTERVAL ((#{7 - week_start} + WEEKDAY(CONVERT_TZ(#{column}, '+00:00', ?) - INTERVAL #{day_start} HOUR)) % 7) DAY) - INTERVAL #{day_start} HOUR, '+00:00', ?), '%Y-%m-%d 00:00:00') + INTERVAL #{day_start} HOUR, ?, '+00:00')", time_zone, time_zone, time_zone]
          else
            format =
              case field
              when :second
                "%Y-%m-%d %H:%i:%S"
              when :minute
                "%Y-%m-%d %H:%i:00"
              when :hour
                "%Y-%m-%d %H:00:00"
              when :day
                "%Y-%m-%d 00:00:00"
              when :month
                "%Y-%m-01 00:00:00"
              else # year
                "%Y-01-01 00:00:00"
              end

            ["DATE_ADD(CONVERT_TZ(DATE_FORMAT(CONVERT_TZ(DATE_SUB(#{column}, INTERVAL #{day_start} HOUR), '+00:00', ?), '#{format}'), ?, '+00:00'), INTERVAL #{day_start} HOUR)", time_zone, time_zone]
          end
        when "PostgreSQL", "PostGIS"
          case field
          when :day_of_week
            ["EXTRACT(DOW from (#{column}::timestamptz AT TIME ZONE ? - INTERVAL '#{day_start} hour'))::integer", time_zone]
          when :hour_of_day
            ["EXTRACT(HOUR from #{column}::timestamptz AT TIME ZONE ? - INTERVAL '#{day_start} hour')::integer", time_zone]
          when :week # start on Sunday, not PostgreSQL default Monday
            ["(DATE_TRUNC('#{field}', (#{column}::timestamptz - INTERVAL '#{week_start} day' - INTERVAL '#{day_start}' hour) AT TIME ZONE ?) + INTERVAL '#{week_start} day' + INTERVAL '#{day_start}' hour) AT TIME ZONE ?", time_zone, time_zone]
          else
            ["(DATE_TRUNC('#{field}', (#{column}::timestamptz - INTERVAL '#{day_start} hour') AT TIME ZONE ?) + INTERVAL '#{day_start} hour') AT TIME ZONE ?", time_zone, time_zone]
          end
        else
          raise "Connection adapter not supported: #{adapter_name}"
        end

      group = relation.group(Groupdate::OrderHack.new(relation.send(:sanitize_sql_array, query), field, time_zone))
      if options[:series] == false
        group
      else
        relation =
          if time_range.is_a?(Range)
            # doesn't matter whether we include the end of a ... range - it will be excluded later
            group.where("#{column} >= ? AND #{column} <= ?", time_range.first, time_range.last)
          else
            group.where("#{column} IS NOT NULL")
          end

        # TODO do not change object state
        @group_index = group.group_values.size - 1

        Groupdate::Series.new(self, relation)
      end
    end

    def perform(relation, method, *args, &block)
      # undo reverse since we do not want this to appear in the query
      reverse = relation.reverse_order_value
      if reverse
        relation = relation.reverse_order
      end
      order = relation.order_values.first
      if order.is_a?(String)
        parts = order.split(" ")
        reverse_order = (parts.size == 2 && parts[0].to_sym == field && parts[1].to_s.downcase == "desc")
        reverse = !reverse if reverse_order
      end

      multiple_groups = relation.group_values.size > 1

      cast_method =
        case field
        when :day_of_week, :hour_of_day
          lambda{|k| k.to_i }
        else
          utc = ActiveSupport::TimeZone["UTC"]
          lambda{|k| (k.is_a?(String) ? utc.parse(k) : k.to_time).in_time_zone(time_zone) }
        end

      count =
        begin
          Hash[ relation.send(method, *args, &block).map{|k, v| [multiple_groups ? k[0...@group_index] + [cast_method.call(k[@group_index])] + k[(@group_index + 1)..-1] : cast_method.call(k), v] } ]
        rescue NoMethodError
          raise "Be sure to install time zone support - https://github.com/ankane/groupdate#for-mysql"
        end

      series(count, 0, multiple_groups, reverse)
    end

    protected

    def time_zone
      @time_zone ||= begin
        time_zone = options[:time_zone] || Groupdate.time_zone || Time.zone || "Etc/UTC"
        time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone]
      end
    end

    def week_start
      @week_start ||= [:mon, :tue, :wed, :thu, :fri, :sat, :sun].index((options[:week_start] || options[:start] || Groupdate.week_start).to_sym)
    end

    def day_start
      @day_start ||= (options[:day_start] || Groupdate.day_start).to_i
    end

    def time_range
      @time_range ||= begin
        time_range = options[:range]
        if !time_range and options[:last]
          step = 1.send(field) if 1.respond_to?(field)
          if step
            now = Time.now
            time_range = round_time(now - (options[:last].to_i - 1).send(field))..now
          end
        end
        time_range
      end
    end

    def series(count, default_value, multiple_groups = false, reverse = false)
      reverse = !reverse if options[:reverse]

      series =
        case field
        when :day_of_week
          0..6
        when :hour_of_day
          0..23
        else
          time_range = self.time_range
          time_range =
            if time_range.is_a?(Range)
              time_range
            else
              # use first and last values
              sorted_keys =
                if multiple_groups
                  count.keys.map{|k| k[@group_index] }.sort
                else
                  count.keys.sort
                end
              sorted_keys.first..sorted_keys.last
            end

          if time_range.first
            series = [round_time(time_range.first)]

            step = 1.send(field)

            while time_range.cover?(series.last + step)
              series << series.last + step
            end

            if multiple_groups
              keys = count.keys.map{|k| k[0...@group_index] + k[(@group_index + 1)..-1] }.uniq
              series = series.reverse if reverse
              keys.flat_map do |k|
                series.map{|s| k[0...@group_index] + [s] + k[@group_index..-1] }
              end
            else
              series
            end
          else
            []
          end
        end

      # reversed above if multiple groups
      if !multiple_groups and reverse
        series = series.to_a.reverse
      end

      key_format =
        if options[:format]
          if options[:format].respond_to?(:call)
            options[:format]
          else
            sunday = time_zone.parse("2014-03-02 00:00:00")
            lambda do |key|
              case field
              when :hour_of_day
                key = sunday + key.hours + day_start.hours
              when :day_of_week
                key = sunday + key.days
              end
              key.strftime(options[:format].to_s)
            end
          end
        else
          lambda{|k| k }
        end

      Hash[series.map do |k|
        [multiple_groups ? k[0...@group_index] + [key_format.call(k[@group_index])] + k[(@group_index + 1)..-1] : key_format.call(k), count[k] || default_value]
      end]
    end

    def round_time(time)
      time = time.to_time.in_time_zone(time_zone) - day_start.hours

      time =
        case field
        when :second
          time.change(:usec => 0)
        when :minute
          time.change(:sec => 0)
        when :hour
          time.change(:min => 0)
        when :day
          time.beginning_of_day
        when :week
          # same logic as MySQL group
          weekday = (time.wday - 1) % 7
          (time - ((7 - week_start + weekday) % 7).days).midnight
        when :month
          time.beginning_of_month
        when :year
          time.beginning_of_year
        when :hour_of_day
          time.hour
        when :day_of_week
          (7 - week_start + ((time.wday - 1) % 7) % 7)
        else
          raise "Invalid field"
        end

      time.is_a?(Time) ? time + day_start.hours : time
    end

  end
end
