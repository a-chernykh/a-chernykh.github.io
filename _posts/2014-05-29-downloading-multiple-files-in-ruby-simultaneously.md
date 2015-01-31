---
layout: post
comments: true
---

We're saving photos of all recognized traffic signs in [RoadAR] on Amazon S3 bucket. There's a regular process when some of those files should be downloaded, cropped and feeded to the machine learning algorithm which produces SVM output file used in our recognizer. The problem that there's quite a few of such files to be downloaded in one batch (can be 300-400k at our current scale). I am going to cover 3 different ways of downloading multiple files in Ruby:

* [Net::HTTP]
* [em-http-request]
* [typhoeus]

We'll be downloading 100 files for testing purposes:

## Net::HTTP

Net::HTTP is a standard Ruby library to perform HTTP requests. We can use persistent connection for multiple requests since we're downloaing files from the same server. That would give us a huge speed increase since we don't have to setup connection for each download. Also, let's spin up some threads to bring concurrency. There will be a lot of network I/O in these threads which does not lock GIL in Ruby.

<script src="https://gist.github.com/andreychernih/5a2b43e5c5cc583e8a69.js"></script>

This will create `thread_count` threads and `thread_count` keep-alive HTTP connections.

## em-http-request

But why threads? We should be able to leverage advantages of [Reactor pattern]. There's an awesome library called [em-http-request] by [igrigorik] which allows to do simultaneous HTTP requests very quickly. It's based on events so that the thread is not blocked while the download operation is performed. Application get notified when non-blocking operation is completed. It uses [EventMachine] under the hood which means download should be executed in `EventMachine.run` loop and [EventMachine] should be stopped manually when all files has been downloaded.

<script src="https://gist.github.com/andreychernih/cefe4c9540925dd46524.js"></script>

`EventMachine::MultiRequest` is a class which executes multiple HTTP requests. It's callback gets called when all requests are finished. I am using `EM::Iterator` to limit our downloader to 100 parallel downloads maximum. `EM::Iterator` is asynchronous iterator which only steps to the next iteration if the number of currently pending iterations is less than given concurrency value. `iterator.next` must be called manually to signal that asynchronous operation has been completed which finishes current iteration.

[em-http-request][em-http-request] [supports persistent server connections][em-http-request-keep-alive] but I was not able to figure out how to make them working properly with Amazon S3. After setting up keep alive connection, the second request always failed for me (`errback` was called with a message that connection was closed).

## typhoeus

[Typhoeus] is a ruby wrapper for [libcurl]. [libcurl] is mature and robust C library for performing HTTP requests. Parallel requests can be executed with `hydra` interface. Concurrency configuration comes out of the box. Persistent connections are also enabled by default since `curl` connection API will atempt to re-use existing connections automatically.

<script src="https://gist.github.com/andreychernih/c0471b75d0de6e9b4a3a.js"></script>

[typhoeus] looks like an easiest to setup solution.

## Benchmarking

Let's do some benchmarks.

<script src="https://gist.github.com/andreychernih/83a486438445d47d92a1.js"></script>

<div class="chart" id="net_http_benchmarks"></div>

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

<script src="{{ "/js/downloading-multiple-files-in-ruby.js" | prepend: site.baseurl }}">
