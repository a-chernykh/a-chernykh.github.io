require 'delicious'
require 'json'
require 'csv'

TAGS_FILE = 'tags.json'
EDGES_FILE = 'tags.csv'

def get_tags
  cache_tags unless File.exist?(TAGS_FILE)
  JSON.parse(File.read(TAGS_FILE))  
end

def cache_tags
  client = Delicious::Client.new do |config|
    config.access_token = '511224-1962076602ff242099702df96944d1b1'
  end

  client.bookmarks.all.each do |bookmark|
    tags << bookmark.tags
  end

  File.open(TAGS_FILE, 'w') { |f| f.write tags.to_json }
end

def save_edges(tags)
  pairs = {}

  tags.each do |tag_set|
    (0...tag_set.length).each do |i|
      (i+1...tag_set.length).each do |j|
        pairs[tag_set[i]] ||= Hash.new(0)
        pairs[tag_set[j]] ||= Hash.new(0)

        if pairs[tag_set[j]][tag_set[i]] > 0
          pairs[tag_set[j]][tag_set[i]] += 1
        else
          pairs[tag_set[i]][tag_set[j]] += 1
        end
      end
    end
  end

  CSV.open(EDGES_FILE, 'wb') do |csv|
    csv << %w(Source Target Weight Type)

    pairs.each do |k1, v|
      v.each do |k2, weight|
        csv << [k1, k2, weight, 'Undirected']
      end
    end
  end
end

tags = get_tags
puts "Loaded #{tags.length} bookmarks"
save_edges(tags) unless File.exist?(EDGES_FILE)
