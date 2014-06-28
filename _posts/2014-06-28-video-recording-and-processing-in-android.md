---
layout: post
comments: true
---

Our [Android app] has an ability to record videos and also process frames as they are coming from camera. Processing includes traffic sign discovery and hard subtitles addition (GPS coordinates and timestamp). So, our final goal is to be able to access raw frames (`byte[]`) and to record video at the same time. It turned out that it's quite hard to perform such kind of tasks on Android simultaneously, but we came up with our own way of doing it. Let's start with what did not work.

## MediaRecorder

[MediaRecorder] is the default and most easiest way to record video in Android. It has been there since API 1 and can record both audio and video. It's the best way for recording if you'd like to get consistent behaviour and minimize number of errors across various devices. Using it as easy as configuring a couple of parameters and calling [MediaRecorder.prepare] followed by [MediaRecorder.start]:

<script src="https://gist.github.com/andreychernih/085820f646ad6d5710ab.js"></script>

Unfortunately, it has one big downside which makes it completely unusable for our needs. It does not supports frames processing. You're setting the source (camera) and destination (file). [MediaRecorder] does all the magic inside and we can't access frames as they're coming. There is [a way](http://hello-qd.blogspot.ru/2013/05/how-to-process-mediarecorder-frames.html) to access those frames though, but it's pretty complex and has some issues. Also, it uses [MediaExtractor] which was first added in [Android 4.3].

## MediaCodec

[Jelly Bean] introduced [MediaCodec] API. It's a low level way to work with device's media codecs. You can take frames coming from camera preview callback, send and then receive them back from specific hardware or software codec on application level.

[Android 4.3] adds some new fancy things which improve [MediaCodec] significantly. You can now mux received frames into video file using [MediaMuxer] API. It's also became possible to pass [Surface] as an input to [MediaCodec] which it will be using to get frames directly. Every device has it's own codecs and every codec supports it's own color formats. Specifying [Surface] as an input is a better alternative to sending raw bytes because you don't have to deal with codec-specific color transformations anymore. It's too bad we can't leverage these features right away because we obviously have to support pre-[Android 4.3] users.

We also have one big problem with [MediaCodec]. It's only working stable and consistent since [Android 4.3]. The reason why it's working bad in pre-[Android 4.3] systems is that it was missing all necessary [CTS tests]. Anyway, we've decided to proceed with [MediaCodec] since we've had no other choices. [MediaCodec] is the only alternative to [MediaRecorder] to encode video using device's hardware encoders.

### Configuration

According to [Dashboards], there are still quite a few devices running Android versions older than [Jelly Bean]. That's why we've decided to support all Android devices running API 11 and higher. We need a fallback to allow older devices to encode videos. We use dependency injection framework [guice] by Google which allows us to perform class bindings in runtime:

<script src="https://gist.github.com/andreychernih/8891c03143294c8fa690.js"></script>

Note `MediaCodecFormatSelector` which we use to determine if we should go with [MediaCodec] or not. We have to use it to minimize number of crashes and various bugs because of older Android versions. Examples of such issues:

* Device freezes while calling [MediaCodec] API function
* [MediaCodec] treats input color format incorrectly and produces videos with invalid colors
* App crashes randomly when calling [MediaCodec] API functions
* [MediaCodec] works inconsistently with various codecs

We've created a list of affected devices and we're forcing MJPEG encoding for them:

<script src="https://gist.github.com/andreychernih/0c2b1b19083ad6b3df78.js"></script>

### Encoder

`VideoEncoder` is a general encoder interface:

<script src="https://gist.github.com/andreychernih/edcd7c2e0681371c5bb1.js"></script>

We are sending and receiving frames in 2 separate threads for maximum throughtput. Muxer also occupies dedicated thread because otherwise it can block receiving thread which, in turn, eventually will block sending thread because of [MediaCodec] buffer which was not released in due time. Don't forget to pass `System.nanoTime() / 1000` as 4th parameter to [MediaCodec.queueInputBuffer] function, otherwise produced video will have invalid duration.

#### Converting color

While received frames can be feeded directly to the muxer, we still need to do some color format processing when we're sending frames to [MediaCodec]. Let's set camera preview format to `ImageFormat.NV21` which is guaranteed to be supported in all devices. It's a [YUV format] with Y plane going first followed by interleaved UV plane (`YYYYYYVUVUVU`). Unfortunately, [MediaCodec] does not supports it as input format. The most popular formats supported by [MediaCodec] are `COLOR_FormatYUV420SemiPlanar` and `COLOR_FormatYUV420Planar` and we need to ensure that we're converting input frames properly:

<script src="https://gist.github.com/andreychernih/394fb8520feddfea979f.js"></script>

### Muxing video

Since we're supporting older Android versions, we can't use [MediaMuxer] yet. There's a good Java library which allows to do video muxing called [Jcodec]. We'll be using it to build final video files out of raw h264 frames sent to us by [MediaCodec].

<script src="https://gist.github.com/andreychernih/f27434a2127481ccd874.js"></script>

One important line to note is `mMp4Track.setTgtChunkDuration(new Rational(2, 1), Unit.SEC)`. It tells [Jcodec] to dump video to the disk every 2 seconds. Otherwise every new frame will produce disk write. According to our tests, disk writing time on some devices may be a subject for slowdown spikes. For example, let's say that problem device usually writes 30kb chunks in 1ms. Every few seconds this time can grow to 200-300ms randomly. That's why it's better to do as less disk writes as possible. I've also [modified Jcodec](https://github.com/andreychernih/jcodec/commit/3028acba3cddec58a60de8f40ba7a7a328159642) slightly because it was throwing `OutOfMemoryError` from time to time.

Unfortunately, [Jcodec] currently does not supports muxing audio. We have to mux audio separately with another library.

### Muxing audio

There's another well-known Java library called [mp4parser] which knows how to deal with video and audio. We're using it for merging video and audio together. That's it, we're muxing video and audio streams simultaneously into 2 separate mp4 files. When recording finished, we're merging them together with [mp4parser]. Here how it looks:

<script src="https://gist.github.com/andreychernih/587251494b80718a3235.js"></script>

You must have noticed [BufferedWritableFileByteChannel] which is not a part of [java.nio] nor [mp4parser]. It's a simple wrapper for [WritableByteChannel] which buffers data up to `BUFFER_CAPACITY` bytes and only does write when it's filled. It helps to overcome random disk write slowness issues.

Also, [mp4parser] was really slow on Android. It took almost 20 seconds to mux 1 minute audio and video together. I went ahead and performed some profiling using [Debug method tracing](http://developer.android.com/reference/android/os/Debug.html) and it resulted in [this patch](https://code.google.com/p/mp4parser/issues/detail?id=90&thanks=90&ts=1401796984) which speeded it up significantly (5 seconds for 1 minute video).

## Conclusion

The whole process is a bit awkward, but it works good for us. [Android 4.3] market share is still pretty low (24% of devices are running [Android 4.3] and higher) and I guess that we won't be able to utilize [MediaCodec] APIs efficiently in nearest future.

## Links

* [Android MediaCodec stuff](http://bigflake.com/mediacodec/)
* [StackOverflow questions](http://stackoverflow.com/questions/tagged/mediacodec)
* [MediaCodec inconsistincies discussion](https://code.google.com/p/android/issues/detail?id=37769)

[Android app]: https://play.google.com/store/apps/details?id=ru.roadar.android
[MediaRecorder]: http://developer.android.com/reference/android/media/MediaRecorder.html
[MediaRecorder.prepare]: http://developer.android.com/reference/android/media/MediaRecorder.html#prepare()
[MediaRecorder.start]: http://developer.android.com/reference/android/media/MediaRecorder.html#start()
[MediaExtractor]: http://developer.android.com/reference/android/media/MediaExtractor.html
[Jelly Bean]: http://www.android.com/about/jelly-bean/
[MediaCodec]: http://developer.android.com/reference/android/media/MediaCodec.html
[MediaMuxer]: http://developer.android.com/reference/android/media/MediaMuxer.html
[Android 4.3]: http://developer.android.com/about/versions/android-4.3.html
[Android 4.4]: http://developer.android.com/about/versions/android-4.4.html
[CTS tests]: https://source.android.com/compatibility/cts-intro.html
[Surface]: http://developer.android.com/reference/android/view/Surface.html
[guice]: https://code.google.com/p/google-guice/
[Dashboards]: https://developer.android.com/about/dashboards/index.html
[YUV format]: http://www.fourcc.org/yuv.php
[Jcodec]: https://github.com/jcodec/jcodec
[MediaCodec.queueInputBuffer]: http://developer.android.com/reference/android/media/MediaCodec.html#queueInputBuffer(int, int, int, long, int)
[mp4parser]: https://code.google.com/p/mp4parser/
[BufferedWritableFileByteChannel]: https://gist.github.com/andreychernih/73d4f56244fc6848ef86
[java.nio]: http://docs.oracle.com/javase/7/docs/api/java/nio/package-summary.html
[WritableByteChannel]: http://docs.oracle.com/javase/7/docs/api/java/nio/channels/WritableByteChannel.html
