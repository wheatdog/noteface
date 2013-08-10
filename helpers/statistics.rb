module Helpers
  module Statistics
    def stats_for(document_name)
      stats = {
        :name => document_name,
        :downloads => 0,
        :users => Hash.new({
          :downloads => 0,
          :first_download => Time.now.to_i,
          :latest_download => 0
        }),
        :days => Hash.new(0),
        :hours => Hash.new(0)
      }

      stats[:downloads] = @redis.scard("#{document_name}:downloads")

      for download in @redis.smembers("#{document_name}:downloads")
        dl = JSON.parse(download)
        time = Time.at(dl["time"])
        ip = dl["ip"]

        # Set default user object, if we haven't seen this user before.
        stats[:users][dl["ip"]] = stats[:users][dl["ip"]]

        stats[:users][dl["ip"]][:downloads] = stats[:users][dl["ip"]][:downloads] + 1

        if Time.at(stats[:users][dl["ip"]][:first_download]) > time
          stats[:users][dl["ip"]][:first_download] = time
        end

        if Time.at(stats[:users][dl["ip"]][:latest_download]) < time
          stats[:users][dl["ip"]][:latest_download] = time
        end

        stats[:days][time.to_date.to_s] = stats[:days][time.to_date.to_s] + 1
        stats[:hours][time.hour] = stats[:hours][time.hour] + 1

      end

      stats
    end

    def all_stats
      documents = @redis.smembers('documents')
      stats = {
        :documents => {},
        :users_count => 0
      }

      users = []

      for document in documents
        stats[:documents][document] = stats_for(document)
        users << stats[:documents][document][:users]
      end

      users.flatten!
      users.uniq!

      stats[:users_count] = users.count

      stats
    end

  end
end