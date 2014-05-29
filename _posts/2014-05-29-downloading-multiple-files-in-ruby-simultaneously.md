---
layout: post
---

We're saving photos of all recognized traffic signs in [RoadAR] on Amazon S3 bucket. There's a regular process when some of those files should be downloaded, cropped and feeded to the machine learning algorithm which produces SVM output file used in our recognizer. The problem that there's quite a few of such files to be downloaed in one batch (can be 300-400k at our current scale). I am going to cover 3 different ways of downloading multiple files in Ruby:

* [Net::HTTP]
* [em-http-request]
* [typhoeus]

We'll be downloading 100 files for testing purposes:

## Net::HTTP

Net::HTTP is a standard Ruby library to perform HTTP requests. We can use persistent connection for multiple requests since we're downloaing files from the same server. That would give us a huge speed increase since we don't have to setup connection for each download. Also, let's spin up some threads to bring concurrency. There will be a lot of network I/O in these threads which does not lock GIL in Ruby.

{% highlight ruby %}
require 'net/http'

def download_net_http(urls, thread_count)
  queue = Queue.new
  urls.map { |url| queue << url }

  threads = thread_count.times.map do
    Thread.new do
      Net::HTTP.start('our-s3-bucket.s3.amazonaws.com', 80) do |http|
        while !queue.empty? && url = queue.pop
          uri = URI(url)
          request = Net::HTTP::Get.new(uri)
          response = http.request request
          write_file url, response.body
        end
      end
    end
  end

  threads.each(&:join)
end
{% endhighlight %}

This will create `thread_count` threads and `thread_count` keep-alive HTTP connections.

## em-http-request

But why threads? We should be able to leverage advantages of [Reactor pattern]. There's an awesome library called [em-http-request] by [igrigorik] which allows to do simultaneous HTTP requests very quickly. It's based on events so that the thread is not blocked while the download operation is performed. Application get notified when non-blocking operation is completed. It uses [EventMachine] under the hood which means download should be executed in `EventMachine.run` loop and [EventMachine] should be stopped manually when all files has been downloaded.

{% highlight ruby %}
require 'em-http'

def download_em_http(urls, concurrency)
  EventMachine.run do
    multi = EventMachine::MultiRequest.new

    EM::Iterator.new(urls, concurrency).each do |url, iterator|
      req = EventMachine::HttpRequest.new(url).get
      req.callback do
        write_file url, req.response
        iterator.next
      end
      multi.add url, req
      multi.callback { EventMachine.stop } if url == urls.last
    end
  end
end
{% endhighlight %}

`EventMachine::MultiRequest` is a class which executes multiple HTTP requests. It's callback gets called when all requests are finished. I am using `EM::Iterator` to limit our downloader to 100 parallel downloads maximum. `EM::Iterator` is asynchronous iterator which only steps to the next iteration if the number of currently pending iterations is less than given concurrency value. `iterator.next` must be called manually to signal that asynchronous operation has been completed which finishes current iteration.

[em-http-request][em-http-request] [supports persistent server connections][em-http-request-keep-alive] but I was not able to figure out how to make them working properly with Amazon S3. After setting up keep alive connection, the second request always failed for me (`errback` was called with a message that connection was closed).

## typhoeus

[Typhoeus] is a ruby wrapper for [libcurl]. [libcurl] is mature and robust C library for performing HTTP requests. Parallel requests can be executed with `hydra` interface. Concurrency configuration comes out of the box. Persistent connections are also enabled by default since `curl` connection API will atempt to re-use existing connections automatically.

{% highlight ruby %}
require 'typhoeus'

def download_typhoeus(urls, concurrency)
  hydra = Typhoeus::Hydra.new(max_concurrency: concurrency)

  urls.each do |url|
    request = Typhoeus::Request.new url
    request.on_complete do |response|
      write_file url, response.body
    end
    hydra.queue request
  end

  hydra.run
end
{% endhighlight %}

[typhoeus] looks like an easiest to setup solution.

## Benchmarking

Let's do some benchmarks.

{% highlight ruby %}
%i(net_http em_http typhoeus).each do |method|
  Benchmark.bm(15) do |x|
    (5..100).step(5) do |c|
      x.report("#{method} #{c}") { send("download_#{method}", urls, c) }
    end
  end
end
{% endhighlight %}

### Net::HTTP

                          user     system      total        real
    net_http 5        0.070000   0.030000   0.100000 (  3.642048)
    net_http 10       0.070000   0.040000   0.110000 (  1.999588)
    net_http 15       0.060000   0.040000   0.100000 (  1.888344)
    net_http 20       0.060000   0.030000   0.090000 (  1.112068)
    net_http 25       0.060000   0.030000   0.090000 (  0.940138)
    net_http 30       0.060000   0.040000   0.100000 (  0.856508)
    net_http 35       0.060000   0.030000   0.090000 (  0.748401)
    net_http 40       0.050000   0.040000   0.090000 (  0.694160)
    net_http 45       0.050000   0.030000   0.080000 (  0.665795)
    net_http 50       0.060000   0.040000   0.100000 (  0.645763)
    net_http 55       0.050000   0.040000   0.090000 (  0.552245)
    net_http 60       0.060000   0.040000   0.100000 (  0.540446)
    net_http 65       0.050000   0.040000   0.090000 (  0.529512)
    net_http 70       0.060000   0.040000   0.100000 (  0.528325)
    net_http 75       0.050000   0.050000   0.100000 (  0.520857)
    net_http 80       0.050000   0.040000   0.090000 (  0.676060)
    net_http 85       0.060000   0.050000   0.110000 (  0.528128)
    net_http 90       0.050000   0.050000   0.100000 (  0.520646)
    net_http 95       0.060000   0.050000   0.110000 (  0.531306)
    net_http 100      0.060000   0.050000   0.110000 (  0.433985)

### em-http-request

We can see a slight hiccup here probably because I was not able to figure out persistent connections.

                          user     system      total        real
    em_http 5         0.130000   0.070000   0.200000 (  5.548172)
    em_http 10        0.110000   0.060000   0.170000 (  2.717937)
    em_http 15        0.100000   0.060000   0.160000 (  1.792095)
    em_http 20        0.090000   0.050000   0.140000 (  1.483924)
    em_http 25        0.090000   0.050000   0.140000 (  1.191819)
    em_http 30        0.070000   0.050000   0.120000 (  1.359472)
    em_http 35        0.080000   0.040000   0.120000 (  1.400285)
    em_http 40        0.070000   0.050000   0.120000 (  0.882688)
    em_http 45        0.070000   0.050000   0.120000 (  0.931467)
    em_http 50        0.090000   0.040000   0.130000 (  0.747024)
    em_http 55        0.080000   0.050000   0.130000 (  2.166063)
    em_http 60        0.070000   0.040000   0.110000 (  0.774504)
    em_http 65        0.060000   0.040000   0.100000 (  0.661807)
    em_http 70        0.070000   0.040000   0.110000 (  0.722347)
    em_http 75        0.060000   0.040000   0.100000 (  1.101692)
    em_http 80        0.050000   0.030000   0.080000 (  0.779493)
    em_http 85        0.060000   0.030000   0.090000 (  0.987961)
    em_http 90        0.060000   0.040000   0.100000 (  4.477732)
    em_http 95        0.060000   0.040000   0.100000 (  1.192294)
    em_http 100       0.060000   0.030000   0.090000 (  0.383410)

### typhoeus

                          user     system      total        real
    typhoeus 5        0.110000   0.050000   0.160000 (  2.751154)
    typhoeus 10       0.100000   0.050000   0.150000 (  1.346880)
    typhoeus 15       0.090000   0.040000   0.130000 (  0.979289)
    typhoeus 20       0.070000   0.040000   0.110000 (  0.768512)
    typhoeus 25       0.080000   0.050000   0.130000 (  0.633797)
    typhoeus 30       0.070000   0.040000   0.110000 (  0.710481)
    typhoeus 35       0.070000   0.040000   0.110000 (  0.554819)
    typhoeus 40       0.060000   0.040000   0.100000 (  0.532209)
    typhoeus 45       0.070000   0.050000   0.120000 (  1.206193)
    typhoeus 50       0.070000   0.050000   0.120000 (  0.611029)
    typhoeus 55       0.060000   0.040000   0.100000 (  0.438923)
    typhoeus 60       0.080000   0.060000   0.140000 (  2.635647)
    typhoeus 65       0.060000   0.040000   0.100000 (  0.683867)
    typhoeus 70       0.060000   0.040000   0.100000 (  0.439284)
    typhoeus 75       0.110000   0.070000   0.180000 (  4.584483)
    typhoeus 80       0.080000   0.050000   0.130000 (  1.978701)
    typhoeus 85       0.060000   0.050000   0.110000 (  0.588366)
    typhoeus 90       0.140000   0.110000   0.250000 (  7.176640)
    typhoeus 95       0.100000   0.070000   0.170000 (  3.593405)
    typhoeus 100      0.970000   1.350000   2.320000 ( 68.177221)


## Conclusion

It all depends on internet connection, server latency and CPU speed. The difference is vague though since it's hard to rely on test results because of many outside factors involved. Personally I find [typhoeus] being the best solution for downloading multiple files because it's based on robust [libcurl] and it's pretty easy to get started with. But if you don't like installing custom gem, it's perfectly fine to stick with [Net::HTTP] since it performs very well when persistent connections are used.

We're currently using [em-http-request] but I am thinking towards migrating to [Net::HTTP] since I don't like to have a large asynchronous library ([EventMachine]) in project when the same task can be performed using standard Ruby library.

[RoadAR]:                     http://roadarapp.com
[Net::HTTP]:                  http://ruby-doc.org/stdlib-2.1.2/libdoc/net/http/rdoc/Net/HTTP.html
[em-http-request]:            https://github.com/igrigorik/em-http-request
[em-http-request-keep-alive]: https://github.com/igrigorik/em-http-request/wiki/Keep-Alive-and-HTTP-Pipelining
[typhoeus]:                   https://github.com/typhoeus/typhoeus
[igrigorik]:                  https://github.com/igrigorik
[EventMachine]:               http://rubyeventmachine.com
[libcurl]:                    http://curl.haxx.se/libcurl/
[Reactor pattern]:            http://en.wikipedia.org/wiki/Reactor_pattern
