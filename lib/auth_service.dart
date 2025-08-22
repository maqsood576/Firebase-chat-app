import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _google = GoogleSignIn();
  final Box _usersBox = Hive.box('users');
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<UserCredential?> signInWithGoogle() async {
    try {
      final googleUser = await _google.signIn();
      if (googleUser == null) {
        print('Google Sign-In cancelled by user');
        return null;
      }

      final googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCred = await _auth.signInWithCredential(credential);
      print('Signed in user: ${userCred.user?.uid}');

      // 🔹 Duplicate Name Restriction
      final sameNameUser = await _firestore
          .collection('users')
          .where('name', isEqualTo: userCred.user?.displayName ?? '')
          .get();

      if (sameNameUser.docs.isNotEmpty &&
          sameNameUser.docs.first.id != userCred.user?.uid) {
        await signOut();
        throw Exception('⚠ A user with this name already exists.');
      }

      await _syncAndSaveUserData(userCred.user!);
      return userCred;
    } catch (e) {
      print("Google Sign-In Error: $e");
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _google.signOut();
      await _auth.signOut();
      print('User signed out successfully');
    } catch (e) {
      print('Sign out error: $e');
      rethrow;
    }
  }

  Future<void> _syncAndSaveUserData(User user) async {
    try {
      final docRef = _firestore.collection('users').doc(user.uid);
      final snapshot = await docRef.get();
      final fcmToken = await FirebaseMessaging.instance.getToken();

      final userData = {
        'uid': user.uid,
        'name': user.displayName ?? '',
        'email': user.email ?? '',
        'photoUrl': user.photoURL ?? '',
        'lastSeen': FieldValue.serverTimestamp(),
        'fcmToken': fcmToken ?? '',
      };

      if (!snapshot.exists) {
        await docRef.set(userData);
      } else {
        await docRef.update({
          'lastSeen': FieldValue.serverTimestamp(),
          'fcmToken': fcmToken ?? FieldValue.delete(),
        });
      }

      await _usersBox.put(user.uid, userData);
    } catch (e) {
      print('Error syncing user: $e');
      rethrow;
    }
  }
}
