using UnityEngine;

namespace DynamicRagdoll
{
    public static class Maths
    {
        public static float COMtoBOSdist(Vector3 bosPoint, Vector3 hipsPoint)
        {
            Vector3 vec = bosPoint - hipsPoint;
            return new Vector3(vec.x, 0f, vec.z).magnitude;
        }
        public static Vector3 GetNextStepPoint(Vector3 groundedFoot, Vector3 bos)
        {
            Vector3 direction = bos - groundedFoot;
            Vector3 nextStep = bos + direction;
            return SetY(nextStep, 0f);
        }
        public static Vector3 SetY(Vector3 vec, float pY)
        {
            return new Vector3(vec.x, pY, vec.z);
        }
        public static Vector3 FuturePosition(this Rigidbody rb, float time)
        {
            Vector3 currentPosition = rb.position;
            Vector3 velocity = rb.linearVelocity;
            Vector3 futurePosition = currentPosition + (velocity * time);
            return futurePosition;
        }
        public static bool DotProduct(Vector3 mainDir, Vector3 relativeDir)
        {
            float dotProduct = Vector3.Dot(mainDir, relativeDir);

            if (dotProduct > 0)
            {
                return true;
            }
            else if (dotProduct < 0)
            {
                return false;
            }
            else
            {
                return false;
            }
        }
        public static int GetDominantAxis(Vector3 vector)
        {
            if (Mathf.Abs(vector.x) > Mathf.Abs(vector.y) && Mathf.Abs(vector.x) > Mathf.Abs(vector.z))
                return vector.x > 0 ? 1 : -1;
            else if (Mathf.Abs(vector.y) > Mathf.Abs(vector.z))
                return vector.y > 0 ? 2 : -2;
            return vector.z > 0 ? 3 : -3;
        }
        public static Vector3 GetAxisVector(int axis)
        {
            switch (axis)
            {
                case 1: return Vector3.right;
                case 2: return Vector3.up;
                case 3: return Vector3.forward;
                case -1: return -Vector3.right;
                case -2: return -Vector3.up;
                case -3: return -Vector3.forward;
                default: return Vector3.zero;
            }
        }
        public static Vector3 GetWorldDir(this Transform main, int axis)
        {
            return main.TransformDirection(Maths.GetAxisVector(axis));
        }
    }
}

