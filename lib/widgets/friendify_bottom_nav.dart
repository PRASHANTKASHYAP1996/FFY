import 'package:flutter/material.dart';

import '../core/theme/friendify_brand.dart';

class FriendifyBottomNavItem {
  const FriendifyBottomNavItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

class FriendifyBottomNav extends StatelessWidget {
  const FriendifyBottomNav({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onTap,
  });

  final int currentIndex;
  final List<FriendifyBottomNavItem> items;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final gutter = FriendifyBrand.navGutter(context);
    final innerHorizontalPadding =
        MediaQuery.sizeOf(context).width < 360 ? 4.0 : 6.0;

    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(gutter, 0, gutter, 10),
        padding: EdgeInsets.symmetric(
          horizontal: innerHorizontalPadding,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF080B1D).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.10),
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 24,
              offset: const Offset(0, 12),
              color: Colors.black.withValues(alpha: 0.35),
            ),
          ],
        ),
        child: Row(
          children: List.generate(items.length, (index) {
            final item = items[index];
            final selected = index == currentIndex;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onTap(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: selected
                        ? FriendifyBrand.pureWhite.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.icon,
                        size: 22,
                        color: selected
                            ? FriendifyBrand.pureWhite
                            : FriendifyBrand.slate,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          color: selected
                              ? FriendifyBrand.pureWhite
                              : FriendifyBrand.slate,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
