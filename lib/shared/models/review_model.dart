class ReviewModel {
  final String id;
  final String callId;
  final String reviewerId;
  final String reviewedUserId;
  final int stars;
  final String comment;
  final DateTime? createdAt;

  const ReviewModel({
    required this.id,
    required this.callId,
    required this.reviewerId,
    required this.reviewedUserId,
    required this.stars,
    required this.comment,
    required this.createdAt,
  });

  factory ReviewModel.fromMap(String id, Map<String, dynamic> data) {
    return ReviewModel(
      id: id,
      callId: (data['callId'] ?? '').toString(),
      reviewerId: (data['reviewerId'] ?? '').toString(),
      reviewedUserId: (data['reviewedUserId'] ?? '').toString(),
      stars: (data['stars'] ?? 0) as int,
      comment: (data['comment'] ?? '').toString(),
      createdAt: _timestampToDate(data['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'callId': callId,
      'reviewerId': reviewerId,
      'reviewedUserId': reviewedUserId,
      'stars': stars,
      'comment': comment,
      'createdAt': createdAt,
    };
  }

  static DateTime? _timestampToDate(dynamic ts) {
    if (ts == null) return null;

    if (ts is DateTime) return ts;

    if (ts.runtimeType.toString() == 'Timestamp') {
      return ts.toDate();
    }

    return null;
  }

  bool get hasComment => comment.trim().isNotEmpty;

  bool get isValidStars => stars >= 1 && stars <= 5;
}