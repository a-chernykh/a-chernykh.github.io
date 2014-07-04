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
    config.access_token = 'my-tok'
  end

  client.bookmarks.all.each do |bookmark|
    tags << bookmark.tags
  end

  File.open(TAGS_FILE, 'w') { |f| f.write tags.to_json }
end

def cache_edges(tags)
  pairs = {}

  tags.each do |tag_set|
    (0...tag_set.length).each do |i|
      (i+1...tag_set.length).each do |j|
        next if i == j
        pairs[tag_set[i]] ||= Hash.new(0)
        pairs[tag_set[i]][tag_set[j]] += 1
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
cache_edges(tags) unless File.exist?(EDGES_FILE)
