import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../game/daily_game.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/forge_frame.dart';

/// This month's and last month's Daily Commissions: done days, missed days
/// to play late, and the month's trophy.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

/// Days needed for each monthly trophy (shared/daily.md).
const bronzeDays = 7;
const silverDays = 15;

final trophyColors = {'bronze': Color(0xFFC07A45), 'silver': Color(0xFFC9CED6), 'gold': Palette.gold};

String _month(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  bool _lastMonth = false;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final shown = _lastMonth ? DateTime.utc(now.year, now.month - 1) : DateTime.utc(now.year, now.month);
    final month = _month(shown);
    final calendar = ref.watch(dailyCalendarProvider(month));
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Commission Calendar', style: displayStyle(20)),
      ),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.7,
        fire: 0.5,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Center(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: true, label: Text(_monthName(DateTime.utc(now.year, now.month - 1)))),
                    ButtonSegment(value: false, label: Text(_monthName(DateTime.utc(now.year, now.month)))),
                  ],
                  selected: {_lastMonth},
                  onSelectionChanged: (s) => setState(() => _lastMonth = s.first),
                ),
              ),
              const SizedBox(height: 14),
              switch (calendar) {
                AsyncValue(:final value?) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TrophyBar(calendar: value, daysInMonth: DateUtils.getDaysInMonth(shown.year, shown.month)),
                    const SizedBox(height: 14),
                    _MonthGrid(month: shown, done: value.days, today: todayUtc()),
                    const SizedBox(height: 12),
                    Text(
                      'Missed a day? Tap it to play it late, any day this month or last. '
                      'Late commissions give 15 XP and a Lore page, but not the streak.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: Palette.steel),
                    ),
                    const SizedBox(height: 18),
                    _AllTrophies(trophies: value.trophies),
                  ],
                ),
                AsyncError(:final error) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(
                        error is ApiException ? error.friendly : "Can't reach the forge right now.",
                        textAlign: TextAlign.center,
                      ),
                      TextButton(
                        onPressed: () => ref.invalidate(dailyCalendarProvider(month)),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
                AsyncData() => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Sign in to keep a calendar.', textAlign: TextAlign.center),
                ),
                _ => Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator(color: Palette.molten)),
                ),
              },
            ],
          ),
        ),
      ),
    );
  }

  static String _monthName(DateTime d) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][d.month - 1];
}

class _TrophyBar extends StatelessWidget {
  const _TrophyBar({required this.calendar, required this.daysInMonth});

  final DailyCalendar calendar;
  final int daysInMonth;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final n = calendar.days.length;
    final trophy = calendar.trophy;
    final next = n < bronzeDays
        ? '${bronzeDays - n} more for bronze'
        : n < silverDays
        ? '${silverDays - n} more for silver'
        : n < daysInMonth
        ? 'Every day for gold (${daysInMonth - n} to go)'
        : 'A perfect month!';
    return ForgePanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          GameIcon('trophy', size: 40, color: trophy == null ? Palette.ash : trophyColors[trophy]!),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy == null ? '$n of $daysInMonth days' : '${_cap(trophy)} trophy · $n of $daysInMonth days',
                  style: text.titleMedium,
                ),
                Text(next, style: text.bodySmall?.copyWith(color: Palette.steel)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _cap(String s) => s[0].toUpperCase() + s.substring(1);

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.done, required this.today});

  final DateTime month;
  final Set<String> done;
  final String today;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final lead = DateTime.utc(month.year, month.month).weekday - 1;
    final cells = <Widget>[
      for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
        Center(
          child: Text(d, style: text.labelMedium?.copyWith(color: Palette.steel)),
        ),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var day = 1; day <= days; day++) _Day(date: _iso(month, day), day: day, done: done, today: today),
    ];
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: cells,
    );
  }

  static String _iso(DateTime m, int day) => '${_month(m)}-${day.toString().padLeft(2, '0')}';
}

class _Day extends StatelessWidget {
  const _Day({required this.date, required this.day, required this.done, required this.today});

  final String date;
  final int day;
  final Set<String> done;
  final String today;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isDone = done.contains(date);
    final isToday = date == today;
    final future = date.compareTo(today) > 0;
    final missed = !isDone && !isToday && !future;
    return Semantics(
      button: !future,
      label:
          '$date${isDone
              ? ', done'
              : missed
              ? ', missed: play late'
              : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: future || isDone ? null : () => context.push(isToday ? '/daily' : '/daily?date=$date'),
        child: Container(
          decoration: BoxDecoration(
            color: isDone
                ? Palette.ember.withValues(alpha: 0.22)
                : future
                ? Palette.forgeBlack.withValues(alpha: 0.4)
                : Palette.soot.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isToday ? Palette.molten : Palette.ash.withValues(alpha: future ? 0.3 : 1),
              width: isToday ? 2 : 1,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isDone) GameIcon('flame', size: 26, color: Palette.molten),
              Positioned(
                top: 3,
                left: 5,
                child: Text(
                  '$day',
                  style: text.labelSmall?.copyWith(
                    color: future
                        ? Palette.ash
                        : isDone
                        ? Palette.whiteHeat
                        : Palette.steel,
                  ),
                ),
              ),
              if (missed) Icon(Icons.play_arrow_rounded, size: 18, color: Palette.steel),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllTrophies extends StatelessWidget {
  const _AllTrophies({required this.trophies});

  final ({int bronze, int silver, int gold}) trophies;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text('Trophy case', style: text.titleMedium),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (name, count) in [
              ('gold', trophies.gold),
              ('silver', trophies.silver),
              ('bronze', trophies.bronze),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  children: [
                    GameIcon('trophy', size: 34, color: trophyColors[name]!),
                    Text('$count', style: displayStyle(18)),
                    Text(_cap(name), style: text.labelSmall),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
