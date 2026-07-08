import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/utils.dart';
import '../screens/storage_analyzer/storage_analyzer_screen.dart';

class SwipableStorageOverview extends StatefulWidget {
  final Function(String) onBrowseVolume;
  final Widget? customizeButton;

  const SwipableStorageOverview({super.key, required this.onBrowseVolume, this.customizeButton});

  @override
  State<SwipableStorageOverview> createState() => _SwipableStorageOverviewState();
}

class _SwipableStorageOverviewState extends State<SwipableStorageOverview> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _buildSkeletonCard(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final borderCol = isDark ? Colors.white.withOpacity(0.05) : theme.colorScheme.primary.withOpacity(0.08);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderCol, width: 1),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withOpacity(0.15) : Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    const ShimmerPlaceholder(width: 32, height: 32, borderRadius: 10),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const ShimmerPlaceholder(width: 120, height: 13, borderRadius: 4),
                          const SizedBox(height: 4),
                          const ShimmerPlaceholder(width: 80, height: 9, borderRadius: 4),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    const ShimmerPlaceholder(width: 52, height: 26, borderRadius: 10),
                  ],
                ),
                const SizedBox(height: 8),
                const ShimmerPlaceholder(width: double.infinity, height: 4, borderRadius: 4),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const ShimmerPlaceholder(width: 65, height: 9, borderRadius: 4),
                    const ShimmerPlaceholder(width: 55, height: 9, borderRadius: 4),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FileManagerProvider>();
    final volumes = provider.storageVolumes;

    // Show shimmering skeleton loading card while spaces are being calculated
    if (volumes.isEmpty || provider.totalStorageBytes == 0) {
      return _buildSkeletonCard(context);
    }

    final theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SizedBox(
                height: 96,
                child: PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemCount: volumes.length,
            physics: const BouncingScrollPhysics(),
            itemBuilder: (context, index) {
              final vol = volumes[index];

              int totalBytes;
              int usedBytes;

              if (vol.isInternal) {
                // Use marketing-rounded capacity (e.g. 128 GB) and adjusted used bytes
                totalBytes = provider.totalStorageBytes > 0 
                    ? provider.totalStorageBytes 
                    : 128 * 1024 * 1024 * 1024;
                
                usedBytes = provider.usedStorageBytes > 0 
                    ? provider.usedStorageBytes 
                    : 84 * 1024 * 1024 * 1024;
              } else {
                // Use raw capacity for external storage (SD Card / USB)
                totalBytes = vol.totalBytes > 0 
                    ? vol.totalBytes 
                    : 32 * 1024 * 1024 * 1024;
                
                usedBytes = vol.usedBytes > 0 
                    ? vol.usedBytes 
                    : 0;
              }

              final int freeBytes = totalBytes - usedBytes;
              final double usedPercentage = totalBytes > 0 ? (usedBytes / totalBytes) : 0.0;

              // Format with 2 decimals to display precise storage e.g. 6.22 GB free / 128.00 GB total
              final String totalStorageStr = FileUtils.formatBytes(totalBytes, 2);
              final String freeStorageStr = FileUtils.formatBytes(freeBytes, 2);

              // Gradients & Colors tailored by storage type
              List<Color> gradientColors;
              IconData iconData;
              Color accentColor;

              if (vol.isInternal) {
                gradientColors = isDark
                    ? const [Color(0xFF1E293B), Color(0xFF0F172A)]
                    : [theme.colorScheme.primary, theme.colorScheme.primary.withOpacity(0.82)];
                iconData = Broken.folder_2;
                accentColor = isDark ? const Color(0xFF38BDF8) : Colors.white;
              } else if (vol.name.toLowerCase().contains('sd')) {
                gradientColors = isDark
                    ? const [Color(0xFF312E81), Color(0xFF1E1B4B)]
                    : const [Color(0xFF4F46E5), Color(0xFF4338CA)];
                iconData = Icons.sd_storage_rounded;
                accentColor = isDark ? const Color(0xFF818CF8) : Colors.white;
              } else {
                gradientColors = isDark
                    ? const [Color(0xFF115E59), Color(0xFF0F4C46)]
                    : const [Color(0xFF0D9488), Color(0xFF0F766E)];
                iconData = Icons.usb_rounded;
                accentColor = isDark ? const Color(0xFF2DD4BF) : Colors.white;
              }

              final iconBgColor = isDark ? accentColor.withOpacity(0.15) : Colors.white.withOpacity(0.25);
              final iconBorderColor = isDark ? accentColor.withOpacity(0.3) : Colors.white.withOpacity(0.4);
              final shadowColor = isDark ? Colors.black.withOpacity(0.2) : Colors.black.withOpacity(0.06);
              final progressBgColor = isDark ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.3);

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: gradientColors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: shadowColor,
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                      border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        onTap: () => widget.onBrowseVolume(vol.path),
                        onLongPress: () {
                          if (vol.isInternal) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => StorageAnalyzerScreen(
                                  initialVolumePath: vol.path,
                                ),
                              ),
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(24),
                        splashColor: Colors.white.withOpacity(0.15),
                        highlightColor: Colors.white.withOpacity(0.08),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 6.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: iconBgColor,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: iconBorderColor, width: 1),
                                    ),
                                    child: Icon(iconData, color: accentColor, size: 16),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          vol.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 1),
                                        Text(
                                          vol.path,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.75),
                                            fontSize: 8,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '浏览',
                                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 9),
                                        ),
                                        SizedBox(width: 1),
                                        Icon(Broken.arrow_right_3, color: Colors.white, size: 9),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(
                                        value: usedPercentage,
                                        backgroundColor: progressBgColor,
                                        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                                        minHeight: 4,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '{freeStorageStr} 可用',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 9),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '/ $totalStorageStr',
                                    style: TextStyle(color: Colors.white.withOpacity(0.75), fontWeight: FontWeight.w500, fontSize: 9),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
            if (widget.customizeButton != null) ...[
              const SizedBox(width: 8),
              widget.customizeButton!,
            ],
          ],
        ),
        if (volumes.length > 1) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              volumes.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                height: 6,
                width: _currentPage == index ? 18 : 6,
                decoration: BoxDecoration(
                  color: _currentPage == index
                      ? (isDark ? theme.colorScheme.primary : theme.colorScheme.primary)
                      : (isDark ? Colors.white30 : Colors.black12),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class ShimmerPlaceholder extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const ShimmerPlaceholder({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.35 + (_controller.value * 0.35),
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.08),
              borderRadius: BorderRadius.circular(widget.borderRadius),
            ),
          ),
        );
      },
    );
  }
}
