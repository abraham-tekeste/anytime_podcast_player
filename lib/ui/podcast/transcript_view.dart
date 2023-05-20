// Copyright 2020-2022 Ben Hills. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:anytime/bloc/podcast/audio_bloc.dart';
import 'package:anytime/entities/episode.dart';
import 'package:anytime/entities/person.dart';
import 'package:anytime/entities/transcript.dart';
import 'package:anytime/l10n/L.dart';
import 'package:anytime/services/audio/audio_player_service.dart';
import 'package:anytime/state/transcript_state_event.dart';
import 'package:anytime/ui/widgets/platform_progress_indicator.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// This class handles the rendering of the podcast transcript (where available).
// ignore: must_be_immutable
class TranscriptView extends StatefulWidget {
  final Episode episode;

  TranscriptView({
    Key key,
    @required this.episode,
  }) : super(key: key);

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final log = Logger('TranscriptView');
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ScrollOffsetListener _scrollOffsetListener = ScrollOffsetListener.create(recordProgrammaticScrolls: false);
  final _transcriptSearchController = TextEditingController();
  StreamSubscription<PositionState> _positionSubscription;
  int position = 0;
  bool autoScroll = true;
  bool autoScrollEnabled = true;
  bool first = true;
  bool scrolling = false;
  String speaker = '';
  RegExp exp = RegExp(r'(^)(?<speaker>[A-Za-z0-9\s]+)(:)');

  @override
  void initState() {
    super.initState();
    final audioBloc = Provider.of<AudioBloc>(context, listen: false);

    Subtitle subtitle;
    int index = 0;
    bool firstParse = true;

    // If the user initiates scrolling, disable auto scroll.
    _scrollOffsetListener.changes.listen((event) {
      if (!scrolling) {
        setState(() {
          autoScroll = false;
        });
      }
    });

    // Listen to playback position updates and scroll to the correct items in the transcript
    // if we have auto scroll enabled.
    _positionSubscription = audioBloc.playPosition.listen((event) {
      if (_itemScrollController.isAttached) {
        var transcript = event.episode?.transcript;

        if (transcript != null && transcript.subtitles.isNotEmpty) {
          if (firstParse) {
            firstParse = false;
            var first = transcript.subtitles[0];

            // If we have a transcript but no speaker value, look at the start of the line
            // and see if a speaker is contained there. This is common in SRT format transcripts.
            // On the first load, check the speaker at the first subtitle.
            if (first != null && first.speaker != null && first.speaker.isEmpty) {
              var match = exp.firstMatch(first.data);

              if (match != null) {
                setState(() {
                  speaker = match.namedGroup('speaker');
                });
              }
            }
          }

          subtitle ??= transcript.subtitles[index];

          // Our we outside the range of our current transcript.
          if (event.position.inMilliseconds < subtitle.start.inMilliseconds ||
              event.position.inMilliseconds > subtitle.end.inMilliseconds) {
            // Will the next in the list do?
            if (transcript.subtitles.length > (index + 1) &&
                event.position.inMilliseconds >= transcript.subtitles[index + 1].start.inMilliseconds &&
                event.position.inMilliseconds < transcript.subtitles[index + 1].end.inMilliseconds) {
              index++;
              subtitle = transcript.subtitles[index];
            } else {
              try {
                subtitle = transcript.subtitles
                    .where((a) => (event.position.inMilliseconds >= a.start.inMilliseconds &&
                        event.position.inMilliseconds < a.end.inMilliseconds))
                    .first;

                if (subtitle != null) {
                  index = transcript.subtitles.indexOf(subtitle);
                }
              } catch (e) {
                log.fine('We failed to find a transcript entry for position ${event.position.inMilliseconds}');
              }
            }

            if (subtitle != null) {
              setState(() {
                if (subtitle.speaker != null && subtitle.speaker.isNotEmpty) {
                  speaker = subtitle.speaker;
                } else {
                  var match = exp.firstMatch(subtitle.data);

                  if (match != null) {
                    speaker = match.namedGroup('speaker');
                  }
                }

                position = subtitle.start.inMilliseconds;
              });
            }

            if (autoScroll) {
              if (first) {
                _itemScrollController.jumpTo(index: index);
                first = false;
              } else {
                scrolling = true;
                _itemScrollController.scrollTo(index: index, duration: Duration(milliseconds: 100)).then((value) {
                  scrolling = false;
                });
              }
            }
          }
        }
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
    _positionSubscription.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final audioBloc = Provider.of<AudioBloc>(context, listen: false);

    return StreamBuilder<TranscriptState>(
        stream: audioBloc.nowPlayingTranscript,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            if (snapshot.data is TranscriptLoadingState) {
              return Align(
                alignment: Alignment.center,
                child: PlatformProgressIndicator(),
              );
            } else if (snapshot.data is TranscriptUnavailableState || !snapshot.data.transcript.transcriptAvailable) {
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: Align(
                  alignment: Alignment.center,
                  child: Text(
                    L.of(context).no_transcript_available_label,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            } else {
              final items = snapshot.data.transcript?.subtitles ?? <Subtitle>[];

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 16.0, right: 16.0),
                    child: TextField(
                      controller: _transcriptSearchController,
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        suffixIcon: IconButton(
                          icon: Icon(Icons.close),
                          onPressed: () {
                            _transcriptSearchController.clear();
                            audioBloc.filterTranscript(TranscriptClearEvent());
                            setState(() {
                              autoScrollEnabled = true;
                            });
                          },
                        ),
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: const BorderRadius.all(Radius.circular(12.0)),
                          gapPadding: 0.0,
                        ),
                        hintText: L.of(context).search_transcript_label,
                      ),
                      onSubmitted: ((search) {
                        if (search.isNotEmpty) {
                          setState(() {
                            autoScrollEnabled = false;
                            autoScroll = false;
                          });
                          audioBloc.filterTranscript(TranscriptFilterEvent(search: search));
                        }
                      }),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0, right: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(L.of(context).auto_scroll_transcript_label),
                        Switch(
                          value: autoScroll,
                          onChanged: autoScrollEnabled
                              ? (bool value) {
                                  setState(() {
                                    autoScroll = value;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (widget.episode.persons.isNotEmpty)
                    Container(
                      padding: EdgeInsets.only(left: 16.0),
                      width: double.infinity,
                      height: 72.0,
                      child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.episode.persons.length,
                          itemBuilder: (BuildContext context, int index) {
                            var person = widget.episode.persons[index];
                            var selected = false;

                            if (speaker != null &&
                                speaker.isNotEmpty &&
                                person.name.toLowerCase().startsWith(speaker.toLowerCase())) {
                              selected = true;
                            }

                            return Padding(
                              padding: const EdgeInsets.only(right: 16.0),
                              child: Container(
                                padding: const EdgeInsets.all(4.0),
                                decoration: BoxDecoration(
                                    color: selected ? Colors.orange : Colors.transparent, shape: BoxShape.circle),
                                child: CircleAvatar(
                                  radius: 28,
                                  backgroundImage: ExtendedImage.network(
                                    person.image,
                                    cache: true,
                                  ).image,
                                  child: Text(''),
                                ),
                              ),
                            );
                          }),
                    ),
                  Expanded(
                    /// A simple way to ensure the builder is visible before attempting to use it.
                    child: LayoutBuilder(builder: (context, constraints) {
                      return constraints.minHeight > 60.0
                          ? Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: ScrollablePositionedList.builder(
                                  itemScrollController: _itemScrollController,
                                  scrollOffsetListener: _scrollOffsetListener,
                                  itemCount: items.length ?? 0,
                                  itemBuilder: (BuildContext context, int index) {
                                    var i = items[index];
                                    return Wrap(
                                      children: [
                                        SubtitleWidget(
                                          subtitle: i,
                                          persons: widget.episode.persons,
                                          highlight: i.start.inMilliseconds == position,
                                        ),
                                      ],
                                    );
                                  }),
                            )
                          : Container();
                    }),
                  ),
                ],
              );
            }
          } else {
            return Container();
          }
        });
  }
}

/// Each transcript is made up of one or more subtitles. Each [Subtitle] represents one
/// line of the transcript. This widget handles rendering the passed line.
class SubtitleWidget extends StatelessWidget {
  final Subtitle subtitle;
  final List<Person> persons;
  final bool highlight;
  static const margin = Duration(milliseconds: 1000);

  const SubtitleWidget({
    Key key,
    this.subtitle,
    this.persons,
    this.highlight,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final audioBloc = Provider.of<AudioBloc>(context, listen: false);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        final p = subtitle.start + margin;

        audioBloc.transitionPosition(p.inSeconds.toDouble());
      },
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 0.0),
        color: highlight ? Theme.of(context).colorScheme.onBackground : Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle.speaker.isEmpty
                  ? _formatDuration(subtitle.start)
                  : '${_formatDuration(subtitle.start)} - ${subtitle.speaker}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              subtitle.data,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Padding(padding: EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 16.0))
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hh = (duration.inHours).toString().padLeft(2, '0');
    final mm = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (duration.inSeconds % 60).toString().padLeft(2, '0');

    return '$hh:$mm:$ss';
  }
}